#include "timeline.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <set>
#include <sstream>
#include <stdexcept>

#include "../diag/diag.hpp"
#include "compositor.hpp"
#include "json.hpp"

namespace cutlab::media {

using Clock = std::chrono::steady_clock;

namespace {

Ticks since(Clock::time_point t0, Clock::time_point t1) {
  const auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
  return mul_div(ns, kTicksPerSecond, 1'000'000'000, Rounding::Down);
}

std::vector<std::string> split_fields(const std::string& line, size_t count, std::string* rest) {
  std::vector<std::string> out;
  size_t i = 0;
  while (out.size() < count) {
    while (i < line.size() && line[i] == ' ') ++i;
    if (i >= line.size()) break;
    const size_t j = line.find(' ', i);
    out.push_back(line.substr(i, j == std::string::npos ? std::string::npos : j - i));
    i = j == std::string::npos ? line.size() : j;
  }
  if (rest) {
    while (i < line.size() && line[i] == ' ') ++i;
    *rest = i < line.size() ? line.substr(i) : std::string();
  }
  return out;
}

int64_t to_int(const std::string& s, int line) {
  try {
    size_t used = 0;
    const long long v = std::stoll(s, &used);
    if (used != s.size()) throw std::invalid_argument(s);
    return v;
  } catch (const std::exception&) {
    throw std::invalid_argument("timeline plan line " + std::to_string(line) + ": bad number '" + s + "'");
  }
}

float to_float(const std::string& s, int line) {
  try {
    size_t used = 0;
    const float v = std::stof(s, &used);
    if (used != s.size() || !std::isfinite(v)) throw std::invalid_argument(s);
    return v;
  } catch (const std::exception&) {
    throw std::invalid_argument("timeline plan line " + std::to_string(line) + ": bad number '" + s + "'");
  }
}

bool to_bool(const std::string& s, int line) {
  if (s == "1") return true;
  if (s == "0") return false;
  throw std::invalid_argument("timeline plan line " + std::to_string(line) + ": expected 0 or 1, got '" + s + "'");
}

// Clip-relative fade gain for sample k of a clip `len` samples long.
float fade_gain(int64_t k, int64_t len, int64_t fin, int64_t fout) {
  float g = 1.0f;
  if (fin > 0 && k < fin) g *= (static_cast<float>(k) + 0.5f) / static_cast<float>(fin);
  if (fout > 0 && k >= len - fout) g *= std::max(0.0f, (static_cast<float>(len - k) - 0.5f) / static_cast<float>(fout));
  return std::clamp(g, 0.0f, 1.0f);
}

}  // namespace

// ------------------------------------------------------------------ plan

TlPlan TlPlan::parse(const std::string& text) {
  TlPlan plan;
  std::istringstream in(text);
  std::string line;
  int n = 0;
  bool header = false;
  TlTrack* track = nullptr;
  // Effects, fades and transitions name their clip; resolved at the end.
  struct PendingFx {
    std::string clip;
    TlEffect fx;
    int line;
  };
  struct PendingFade {
    std::string clip;
    Ticks in, out;
    int line;
  };
  struct PendingTin {
    std::string clip;
    TlTransitionIn tin;
    int line;
  };
  std::vector<PendingFx> pending_fx;
  std::vector<PendingFade> pending_vfade;
  std::vector<PendingTin> pending_tin;
  while (std::getline(in, line)) {
    ++n;
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty() || line[0] == '#') continue;
    std::string rest;
    const auto f = split_fields(line, 1, &rest);
    const std::string& kw = f[0];
    if (!header) {
      if (kw != "cutlab-timeline" || rest != "1") throw std::invalid_argument("timeline plan: expected 'cutlab-timeline 1' header");
      header = true;
      continue;
    }
    if (kw == "master") {
      plan.master = std::clamp(to_float(rest, n), 0.0f, 2.0f);
    } else if (kw == "hardware") {
      plan.hardware = to_bool(rest, n);
    } else if (kw == "track") {
      const auto t = split_fields(line, 7, nullptr);
      if (t.size() != 7) throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": track needs 6 fields");
      TlTrack tr;
      tr.id = t[1];
      if (t[2] == "video") {
        tr.kind = TlKind::video;
      } else if (t[2] == "image") {
        tr.kind = TlKind::image;
      } else if (t[2] == "audio") {
        tr.kind = TlKind::audio;
      } else {
        throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": unknown track kind '" + t[2] + "'");
      }
      tr.muted = to_bool(t[3], n);
      tr.solo = to_bool(t[4], n);
      tr.hidden = to_bool(t[5], n);
      tr.volume = std::clamp(to_float(t[6], n), 0.0f, 2.0f);
      plan.tracks.push_back(std::move(tr));
      track = &plan.tracks.back();
    } else if (kw == "clip") {
      if (!track) throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": clip before any track");
      std::string uri;
      const auto c = split_fields(line, 11, &uri);
      if (c.size() != 11 || uri.empty()) throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": clip needs 11 fields");
      TlClip clip;
      clip.id = c[1];
      clip.start = to_int(c[2], n);
      clip.duration = to_int(c[3], n);
      clip.src_in = to_int(c[4], n);
      clip.volume = std::clamp(to_float(c[5], n), 0.0f, 2.0f);
      clip.fade_in = std::max<Ticks>(0, to_int(c[6], n));
      clip.fade_out = std::max<Ticks>(0, to_int(c[7], n));
      clip.audio = to_bool(c[8], n);
      clip.still = to_bool(c[9], n);
      // c[10] is reserved (speed; only 1 is supported).
      if (c[10] != "1") throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": only speed 1 is supported");
      clip.uri = uri;
      if (clip.start < 0 || clip.duration <= 0 || clip.src_in < 0) {
        throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": negative time or empty clip");
      }
      plan.duration = std::max(plan.duration, clip.end());
      track->clips.push_back(std::move(clip));
    } else if (kw == "duration") {
      // Export: the project length (titles may end after the last clip).
      plan.duration = std::max(plan.duration, std::max<Ticks>(0, to_int(rest, n)));
    } else if (kw == "overlay") {
      std::string path;
      const auto o = split_fields(line, 7, &path);
      if (o.size() != 7 || path.empty()) throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": overlay needs 7 fields");
      TlOverlay ov;
      ov.start = to_int(o[1], n);
      ov.duration = to_int(o[2], n);
      ov.x = static_cast<int>(to_int(o[3], n));
      ov.y = static_cast<int>(to_int(o[4], n));
      ov.w = static_cast<int>(to_int(o[5], n));
      ov.h = static_cast<int>(to_int(o[6], n));
      ov.path = path;
      if (ov.start < 0 || ov.duration <= 0 || ov.w <= 0 || ov.h <= 0 || ov.w > 16384 || ov.h > 16384) {
        throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": bad overlay");
      }
      plan.duration = std::max(plan.duration, ov.end());
      plan.overlays.push_back(std::move(ov));
    } else if (kw == "canvas") {
      const auto c = split_fields(line, 3, nullptr);
      if (c.size() != 3) throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": canvas needs width and height");
      plan.canvas_w = static_cast<int>(to_int(c[1], n));
      plan.canvas_h = static_cast<int>(to_int(c[2], n));
      if (plan.canvas_w < 16 || plan.canvas_h < 16 || plan.canvas_w > 16384 || plan.canvas_h > 16384) {
        throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": bad canvas size");
      }
    } else if (kw == "fps") {
      const auto c = split_fields(line, 3, nullptr);
      if (c.size() != 3) throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": fps needs numerator and denominator");
      const int64_t num = to_int(c[1], n), den = to_int(c[2], n);
      if (num <= 0 || den <= 0 || num / den > 240) throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": bad fps");
      plan.fps = Rational::make(num, den);
    } else if (kw == "preview") {
      plan.preview_height = std::clamp(static_cast<int>(to_int(rest, n)), 0, 4320);
    } else if (kw == "effect") {
      // effect <clip> <type> [name=value,...]
      std::string params;
      const auto e = split_fields(line, 3, &params);
      if (e.size() != 3) throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": effect needs a clip and a type");
      TlEffect fx;
      fx.type = e[2];
      size_t i = 0;
      while (i < params.size()) {
        size_t j = params.find(',', i);
        if (j == std::string::npos) j = params.size();
        const std::string kv = params.substr(i, j - i);
        const size_t eq = kv.find('=');
        if (eq == std::string::npos || eq == 0) throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": bad effect parameter '" + kv + "'");
        fx.params[kv.substr(0, eq)] = to_float(kv.substr(eq + 1), n);
        i = j + 1;
      }
      std::string err;
      if (!normalize_effect(fx, &err)) throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": " + err);
      pending_fx.push_back({e[1], std::move(fx), n});
    } else if (kw == "vfade") {
      const auto v = split_fields(line, 4, nullptr);
      if (v.size() != 4) throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": vfade needs a clip, in and out");
      pending_vfade.push_back({v[1], std::max<Ticks>(0, to_int(v[2], n)), std::max<Ticks>(0, to_int(v[3], n)), n});
    } else if (kw == "transition") {
      // transition <clip> <kind> <left> <right> <direction>
      const auto v = split_fields(line, 6, nullptr);
      if (v.size() != 6) throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": transition needs 5 fields");
      TlTransitionIn tin;
      tin.on = true;
      if (!parse_transition(v[2], &tin.kind)) throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": unknown transition '" + v[2] + "'");
      tin.left = std::max<Ticks>(0, to_int(v[3], n));
      tin.right = std::max<Ticks>(0, to_int(v[4], n));
      if (!parse_direction(v[5], &tin.dir)) throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": unknown direction '" + v[5] + "'");
      if (tin.left + tin.right > 0) pending_tin.push_back({v[1], tin, n});
    } else {
      throw std::invalid_argument("timeline plan line " + std::to_string(n) + ": unknown entry '" + kw + "'");
    }
  }
  if (!header) throw std::invalid_argument("timeline plan: empty");
  for (auto& t : plan.tracks) {
    std::sort(t.clips.begin(), t.clips.end(), [](const TlClip& a, const TlClip& b) { return a.start < b.start; });
  }
  auto find_clip = [&](const std::string& id, int line_no) -> TlClip& {
    for (auto& t : plan.tracks)
      for (auto& c : t.clips)
        if (c.id == id) return c;
    throw std::invalid_argument("timeline plan line " + std::to_string(line_no) + ": no clip '" + id + "'");
  };
  for (auto& p : pending_fx) find_clip(p.clip, p.line).effects.push_back(std::move(p.fx));
  for (auto& p : pending_vfade) {
    TlClip& c = find_clip(p.clip, p.line);
    // Fade in and out together at most cover the clip.
    c.vfade_in = std::min(p.in, c.duration);
    c.vfade_out = std::min(p.out, c.duration - c.vfade_in);
  }
  for (auto& p : pending_tin) find_clip(p.clip, p.line).tin = p.tin;
  // Transitions need the clip before, ending exactly at the cut. Each side
  // takes at most half of its clip, so the two transitions of a clip never
  // overlap; an overlap cannot reach before the start of the media.
  for (auto& t : plan.tracks) {
    if (t.kind == TlKind::audio) {
      for (auto& c : t.clips) c.tin.on = false;
    }
    for (size_t i = 0; i < t.clips.size(); ++i) {
      TlClip& b = t.clips[i];
      if (!b.tin.on) continue;
      if (i == 0 || t.clips[i - 1].end() != b.start) {
        b.tin.on = false;
        continue;
      }
      TlClip& a = t.clips[i - 1];
      b.tin.left = std::min(b.tin.left, a.duration / 2);
      b.tin.right = std::min(b.tin.right, b.duration / 2);
      if (transition_overlaps(b.tin.kind)) b.tin.left = std::min(b.tin.left, b.src_in);
      if (b.tin.left + b.tin.right <= 0) {
        b.tin.on = false;
        continue;
      }
      if (transition_overlaps(b.tin.kind)) {
        b.lead = b.tin.left;
        a.tail = b.tin.right;
        a.xfade_out_left = b.tin.left;
      }
    }
  }
  for (const auto& t : plan.tracks) {
    if (t.kind == TlKind::audio) continue;
    for (const auto& c : t.clips) plan.composite = plan.composite || c.styled() || c.tin.on;
  }
  return plan;
}

bool TlPlan::any_solo() const {
  return std::any_of(tracks.begin(), tracks.end(), [](const TlTrack& t) { return t.solo; });
}

bool TlPlan::audible(const TlTrack& t) const { return !t.muted && (t.solo || !any_solo()); }

std::vector<TlSegment> picture_segments(const TlPlan& plan) {
  std::set<Ticks> cuts{0, plan.duration};
  for (const auto& t : plan.tracks) {
    if (t.hidden || t.kind == TlKind::audio) continue;
    for (const auto& c : t.clips) {
      cuts.insert(c.start);
      cuts.insert(c.end());
    }
  }
  std::vector<TlSegment> out;
  Ticks prev = -1;
  for (const Ticks cut : cuts) {
    if (prev >= 0 && cut > prev && prev < plan.duration) {
      const TlClip* top = nullptr;
      for (auto t = plan.tracks.rbegin(); t != plan.tracks.rend() && !top; ++t) {
        if (t->hidden || t->kind == TlKind::audio) continue;
        for (const auto& c : t->clips) {
          if (c.start <= prev && prev < c.end()) {
            top = &c;
            break;
          }
        }
      }
      if (!out.empty() && out.back().clip == top && out.back().end == prev) {
        out.back().end = cut;  // same picture continues
      } else {
        out.push_back({prev, cut, top});
      }
    }
    prev = cut;
  }
  return out;
}

std::string picture_signature(const TlPlan& plan) {
  std::ostringstream s;
  s << plan.hardware << ';';
  if (plan.composite) {
    // Everything that changes a composed picture.
    s << "c" << plan.canvas_w << 'x' << plan.canvas_h << '@' << plan.fps.num << '/' << plan.fps.den << 'p' << plan.preview_height << ';';
    for (const auto& t : plan.tracks) {
      if (t.kind == TlKind::audio) continue;
      s << 't' << t.hidden;
      for (const auto& c : t.clips) {
        s << '[' << c.id << '@' << c.start << '+' << c.duration << '@' << c.src_in << '@' << c.uri << " v" << c.vfade_in << ',' << c.vfade_out;
        if (c.tin.on) s << " t" << static_cast<int>(c.tin.kind) << ',' << static_cast<int>(c.tin.dir) << ',' << c.tin.left << ',' << c.tin.right;
        for (const auto& e : c.effects) {
          s << ' ' << e.type;
          for (const auto& [k, v] : e.params) s << ',' << k << '=' << v;
        }
        s << ']';
      }
      s << ';';
    }
  }
  for (const auto& seg : picture_segments(plan)) {
    s << seg.start << '-' << seg.end << ':';
    if (seg.clip) s << seg.clip->id << '@' << seg.clip->src_in << '@' << seg.clip->start << '@' << seg.clip->uri;
    s << ';';
  }
  return s.str();
}

// ----------------------------------------------------------------- mixer

std::unique_ptr<Mixer::Source> Mixer::open(const TlClip& c, int64_t clip_sample, std::string* error) {
  auto s = std::make_unique<Source>();
  try {
    s->dec = std::make_unique<AudioDecoder>(media::Source::parse(c.uri), kMixRate, kMixChannels);
    s->dec->seek(c.src_in + samples_to_ticks(clip_sample));
    s->next = clip_sample;
  } catch (const std::exception& e) {
    // No sound in this file (or it cannot be read): the clip stays silent.
    s->dec.reset();
    s->failed = true;
    if (error) *error = e.what();
  }
  return s;
}

Mixer::Source* Mixer::source_for(const TlClip& c, int64_t clip_sample) {
  const std::string k = key(c);
  {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = sources_.find(k);
    if (it != sources_.end()) return it->second.get();
    auto r = ready_.find(k);
    if (r != ready_.end()) {
      Source* s = r->second.get();
      sources_[k] = std::move(r->second);
      ready_.erase(r);
      return s;
    }
  }
  std::string err;
  auto s = open(c, clip_sample, &err);
  std::lock_guard<std::mutex> lock(mu_);
  if (!err.empty()) {
    error_ = err;
    diag::note("mixer: clip without usable audio (%s)", err.c_str());
  }
  Source* raw = s.get();
  sources_[k] = std::move(s);
  return raw;
}

void Mixer::forget_far(const TlPlan& plan, int64_t pos) {
  std::set<std::string> keep;
  for (const auto& t : plan.tracks) {
    for (const auto& c : t.clips) {
      const int64_t cs = ticks_to_samples(c.start - c.lead), ce = ticks_to_samples(c.end() + c.tail);
      // Keep decoders around the playhead (a short seek back reuses them).
      if (ce >= pos - kMixRate && cs <= pos + 10LL * kMixRate) keep.insert(key(c));
    }
  }
  std::lock_guard<std::mutex> lock(mu_);
  for (auto it = sources_.begin(); it != sources_.end();) it = keep.count(it->first) ? std::next(it) : sources_.erase(it);
  for (auto it = ready_.begin(); it != ready_.end();) it = keep.count(it->first) ? std::next(it) : ready_.erase(it);
}

void Mixer::render(const TlPlan& plan, int64_t pos, size_t frames, float* out, float* track_peaks, float* master_peak) {
  std::fill(out, out + frames * kMixChannels, 0.0f);
  if (track_peaks) std::fill(track_peaks, track_peaks + plan.tracks.size(), 0.0f);
  const int64_t end = pos + static_cast<int64_t>(frames);
  const float master = plan.master;
  for (size_t ti = 0; ti < plan.tracks.size(); ++ti) {
    const TlTrack& tr = plan.tracks[ti];
    if (!plan.audible(tr) || tr.volume <= 0.0f) continue;
    float peak = 0.0f;
    for (const TlClip& c : tr.clips) {
      if (!c.audio || c.volume <= 0.0f) continue;
      // Heard over [start - lead, end + tail): overlap transitions cross-fade.
      const int64_t c0 = ticks_to_samples(c.start);
      const int64_t cs = ticks_to_samples(c.start - c.lead), ce = ticks_to_samples(c.end() + c.tail);
      if (ce <= pos || cs >= end) continue;
      const int64_t from = std::max(cs, pos), to = std::min(ce, end);
      const int64_t k0 = from - c0;  // clip-relative (negative in the lead)
      Source* s = source_for(c, k0);
      if (!s || s->failed || !s->dec) continue;
      const size_t n = static_cast<size_t>(to - from);
      tmp_.resize(n * kMixChannels);
      size_t got = 0;
      try {
        if (s->next != k0) {
          s->dec->seek(c.src_in + samples_to_ticks(k0));
          s->next = k0;
        }
        got = s->dec->read(tmp_.data(), n);
        s->next += static_cast<int64_t>(got);
      } catch (const std::exception& e) {
        s->failed = true;
        std::lock_guard<std::mutex> lock(mu_);
        error_ = e.what();
        diag::note("mixer: audio decoding stopped (%s)", e.what());
        continue;
      }
      const int64_t len = ticks_to_samples(c.end()) - c0;
      const int64_t fin = ticks_to_samples(c.fade_in), fout = ticks_to_samples(c.fade_out);
      const float gain = tr.volume * c.volume;
      // Equal-power cross-fades: in over [-L, R], out over [len - L', len + tail].
      const bool xin = c.lead > 0 || (c.tin.on && transition_overlaps(c.tin.kind));
      const int64_t in_l = ticks_to_samples(c.lead), in_r = xin ? ticks_to_samples(c.tin.right) : 0;
      const int64_t out_l = ticks_to_samples(c.xfade_out_left), out_r = ticks_to_samples(c.tail);
      const bool xout = out_l + out_r > 0;
      float* dst = out + (from - pos) * kMixChannels;
      for (size_t i = 0; i < got; ++i) {
        const int64_t k = k0 + static_cast<int64_t>(i);
        float g = (fin > 0 || fout > 0) ? gain * fade_gain(std::clamp<int64_t>(k, 0, std::max<int64_t>(0, len - 1)), len, fin, fout) : gain;
        if (xin && in_l + in_r > 0 && k < in_r) {
          const double p = std::clamp(static_cast<double>(k + in_l) + 0.5, 0.0, static_cast<double>(in_l + in_r)) / static_cast<double>(in_l + in_r);
          g *= static_cast<float>(std::sin(p * 1.5707963267948966));
        }
        if (xout && k >= len - out_l) {
          const double p = std::clamp(static_cast<double>(k - (len - out_l)) + 0.5, 0.0, static_cast<double>(out_l + out_r)) / static_cast<double>(out_l + out_r);
          g *= static_cast<float>(std::cos(p * 1.5707963267948966));
        }
        const float l = tmp_[2 * i] * g, r = tmp_[2 * i + 1] * g;
        peak = std::max(peak, std::max(std::fabs(l), std::fabs(r)));
        dst[2 * i] += l * master;
        dst[2 * i + 1] += r * master;
      }
    }
    if (track_peaks) track_peaks[ti] = peak;
  }
  float mpeak = 0.0f;
  int64_t clipped = 0;
  for (size_t i = 0; i < frames * kMixChannels; ++i) {
    const float a = std::fabs(out[i]);
    if (a > 1.0f) {
      ++clipped;
      out[i] = std::clamp(out[i], -1.0f, 1.0f);
    }
    mpeak = std::max(mpeak, std::min(a, 1.0f));
  }
  if (clipped) clipped_ += clipped;
  if (master_peak) *master_peak = mpeak;
  if (++renders_ % 32 == 0) forget_far(plan, pos);
}

void Mixer::prepare(const TlPlan& plan, int64_t pos, int64_t ahead) {
  for (const auto& tr : plan.tracks) {
    if (!plan.audible(tr) || tr.volume <= 0.0f) continue;
    for (const auto& c : tr.clips) {
      if (!c.audio || c.volume <= 0.0f) continue;
      const int64_t c0 = ticks_to_samples(c.start);
      const int64_t cs = ticks_to_samples(c.start - c.lead), ce = ticks_to_samples(c.end() + c.tail);
      if (ce <= pos || cs >= pos + ahead) continue;
      const std::string k = key(c);
      {
        std::lock_guard<std::mutex> lock(mu_);
        if (sources_.count(k) || ready_.count(k)) continue;
      }
      std::string err;
      auto s = open(c, std::max<int64_t>(cs - c0, pos - c0), &err);
      std::lock_guard<std::mutex> lock(mu_);
      if (!sources_.count(k) && !ready_.count(k)) ready_[k] = std::move(s);
    }
  }
}

int Mixer::decoders_open() const {
  std::lock_guard<std::mutex> lock(mu_);
  int n = 0;
  for (const auto& [k, s] : sources_) n += s->dec ? 1 : 0;
  for (const auto& [k, s] : ready_) n += s->dec ? 1 : 0;
  return n;
}

std::string Mixer::last_error() const {
  std::lock_guard<std::mutex> lock(mu_);
  return error_;
}

// ---------------------------------------------------------------- player

TimelinePlayer::TimelinePlayer(TimelineOptions opts) : opts_(opts) {
  plan_ = std::make_shared<TlPlan>();
  segments_ = std::make_shared<std::vector<TlSegment>>();
  ring_capacity_ = static_cast<size_t>(kMixRate / 5) * kMixChannels;  // 0.2 s
  out_ = std::make_unique<AudioOutput>();
  audio_device_ok_ = out_->open(&TimelinePlayer::audio_trampoline, this, opts_.null_audio_device);
  if (!audio_device_ok_) out_.reset();
  diag::note("timeline player open: audio device=%d (%s) preview=%dx%d", audio_device_ok_ ? 1 : 0, out_ ? out_->backend() : "none",
             opts_.max_width, opts_.max_height);
  video_thread_ = std::thread(&TimelinePlayer::video_loop, this);
  mix_thread_ = std::thread(&TimelinePlayer::mix_loop, this);
  prepare_thread_ = std::thread(&TimelinePlayer::prepare_loop, this);
}

TimelinePlayer::~TimelinePlayer() {
  {
    std::lock_guard<std::mutex> lock(mu_);
    quit_ = true;
    playing_ = false;
  }
  cv_.notify_all();
  if (out_) out_->stop();
  if (video_thread_.joinable()) video_thread_.join();
  if (mix_thread_.joinable()) mix_thread_.join();
  if (prepare_thread_.joinable()) prepare_thread_.join();
  out_.reset();
  diag::note("timeline player closed (frames shown %lld, dropped %lld, underruns %lld)", static_cast<long long>(frames_shown_),
             static_cast<long long>(frames_dropped_), static_cast<long long>(underruns_));
}

void TimelinePlayer::set_plan(std::shared_ptr<const TlPlan> plan) {
  auto segs = std::make_shared<std::vector<TlSegment>>(picture_segments(*plan));
  std::string sig = picture_signature(*plan);
  {
    std::lock_guard<std::mutex> lock(mu_);
    const bool picture_changed = sig != picture_sig_;
    plan_ = std::move(plan);
    segments_ = std::move(segs);
    picture_sig_ = std::move(sig);
    if (picture_changed) {
      // Pictures changed: show the new picture at the current time. The
      // sound keeps playing (the mixer reads the new plan for its next block).
      const Ticks t = position_locked();
      ++generation_;
      vseek_pending_ = true;
      vseek_target_ = std::min(t, std::max<Ticks>(0, plan_->duration));
      vseek_accurate_ = true;
      queue_.clear();
      video_eof_ = false;
      prepared_ = PreparedVideo{};
    }
  }
  cv_.notify_all();
}

std::shared_ptr<const TlPlan> TimelinePlayer::plan() const {
  std::lock_guard<std::mutex> lock(mu_);
  return plan_;
}

Ticks TimelinePlayer::position_locked() const {
  if (!playing_) return paused_at_;
  Ticks t;
  if (audio_device_ok_) {
    t = base_ + mul_div(consumed_, kTicksPerSecond, kMixRate, Rounding::Down);
    if (consumed_ > 0) t += std::min<Ticks>(since(last_callback_, Clock::now()), kTicksPerSecond * 3 / 100);
    t = std::max(base_, t - out_->latency());
  } else {
    t = base_ + since(started_, Clock::now());
  }
  const Ticks d = plan_->duration;
  return d > 0 ? std::min(t, d) : t;
}

Ticks TimelinePlayer::position() const {
  std::lock_guard<std::mutex> lock(mu_);
  return position_locked();
}

Ticks TimelinePlayer::duration() const {
  std::lock_guard<std::mutex> lock(mu_);
  return plan_->duration;
}

bool TimelinePlayer::playing() const {
  std::lock_guard<std::mutex> lock(mu_);
  return playing_;
}

void TimelinePlayer::reposition_locked(Ticks t, bool accurate) {
  ++generation_;
  vseek_pending_ = true;
  vseek_target_ = t;
  vseek_accurate_ = accurate;
  aseek_pending_ = true;
  queue_.clear();
  ring_.clear();
  level_hist_.clear();
  video_eof_ = false;
  base_ = t;
  paused_at_ = t;
  consumed_ = 0;
  started_ = Clock::now();
  last_callback_ = started_;
}

void TimelinePlayer::play() {
  bool start_device = false;
  {
    std::lock_guard<std::mutex> lock(mu_);
    if (playing_ || plan_->duration <= 0) return;
    if (paused_at_ >= plan_->duration) reposition_locked(0, true);  // at the end: from the start
    base_ = paused_at_;
    consumed_ = 0;
    started_ = Clock::now();
    last_callback_ = started_;
    play_wall_start_ = started_;
    play_samples_at_start_ = 0;
    playing_ = true;
    start_device = out_ != nullptr;
  }
  cv_.notify_all();
  if (start_device) out_->start();
}

void TimelinePlayer::pause() {
  {
    std::lock_guard<std::mutex> lock(mu_);
    if (!playing_) return;
    paused_at_ = audio_device_ok_ ? base_ + mul_div(consumed_, kTicksPerSecond, kMixRate, Rounding::Down) : position_locked();
    paused_at_ = std::min(paused_at_, std::max<Ticks>(0, plan_->duration));
    playing_ = false;
    // Continue exactly where the audio left off: drop what was mixed ahead.
    reposition_locked(paused_at_, true);
  }
  if (out_) out_->stop();
  cv_.notify_all();
}

void TimelinePlayer::seek(Ticks t, bool accurate) {
  {
    std::lock_guard<std::mutex> lock(mu_);
    const Ticks d = plan_->duration;
    t = std::max<Ticks>(0, d > 0 ? std::min(t, d) : t);
    reposition_locked(t, accurate);
  }
  cv_.notify_all();
}

void TimelinePlayer::update_end_locked() {
  if (playing_ && plan_->duration > 0 && position_locked() >= plan_->duration) {
    paused_at_ = plan_->duration;
    playing_ = false;
  }
}

size_t TimelinePlayer::queue_bytes_locked() const {
  size_t n = 0;
  for (const auto& q : queue_) n += q.frame.rgba.size();
  return n;
}

// ------------------------------------------------------------ video thread

std::unique_ptr<VideoDecoder> TimelinePlayer::open_video(const TlClip& c, const TlPlan& plan) {
  DecodeOptions o;
  o.max_width = opts_.max_width;
  o.max_height = opts_.max_height;
  o.prefer_hardware = plan.hardware && !c.still;
  return std::make_unique<VideoDecoder>(Source::parse(c.uri), o);
}

TimelinePlayer::ActiveVideo& TimelinePlayer::video_for(const TlClip& c, const TlPlan& plan) {
  const std::string k = video_key(c);
  for (auto& a : active_) {
    if (a.key == k) return a;
  }
  ActiveVideo a;
  a.key = k;
  {
    std::lock_guard<std::mutex> lock(mu_);
    if (prepared_.key == k && prepared_.dec) {
      a.dec = std::move(prepared_.dec);
      prepared_ = PreparedVideo{};
    }
  }
  if (!a.dec) a.dec = open_video(c, plan);
  // At most the clip being shown and the one before it stay open.
  if (active_.size() >= 2) active_.erase(active_.begin());
  active_.push_back(std::move(a));
  return active_.back();
}

std::vector<TimelinePlayer::QFrame> TimelinePlayer::enter_segment(const std::vector<TlSegment>& segs, const TlPlan& plan, size_t i) {
  std::vector<QFrame> out;
  cur_seg_ = i;
  if (i >= segs.size()) return out;
  const TlSegment& seg = segs[i];
  if (!seg.clip) {
    out.push_back({seg.start, VideoFrame{}});  // black
    return out;
  }
  const TlClip& c = *seg.clip;
  ++transitions_;
  // A decoder prepared for exactly this segment already holds its first frame.
  {
    std::unique_lock<std::mutex> lock(mu_);
    if (prepared_.key == video_key(c) && prepared_.seg_start == seg.start && prepared_.dec && prepared_.has_first) {
      ActiveVideo a;
      a.key = prepared_.key;
      a.dec = std::move(prepared_.dec);
      VideoFrame f = std::move(prepared_.first);
      prepared_ = PreparedVideo{};
      ++prepared_hits_;
      lock.unlock();
      const Ticks t = std::max(seg.start, to_timeline(c, f.pts));
      a.last_pts = t;
      if (active_.size() >= 2) active_.erase(active_.begin());
      active_.push_back(std::move(a));
      out.push_back({t, std::move(f)});
      return out;
    }
  }
  ActiveVideo& a = video_for(c, plan);
  // The same clip continuing after an overlap ended needs no seek.
  const Ticks frame_ticks = a.dec->frame_rate().num > 0 ? frames_to_ticks(1, a.dec->frame_rate()) : kTicksPerSecond / 30;
  const bool continuous = a.last_pts >= 0 && a.last_pts < seg.start && a.last_pts >= seg.start - 2 * frame_ticks;
  if (!continuous) a.dec->seek(c.src_in + (seg.start - c.start), true);
  VideoFrame f;
  if (a.dec->next(f)) {
    const Ticks t = std::max(seg.start, to_timeline(c, f.pts));
    a.last_pts = t;
    out.push_back({t, std::move(f)});
  } else {
    out.push_back({seg.start, VideoFrame{}});
  }
  return out;
}

std::vector<TimelinePlayer::QFrame> TimelinePlayer::video_seek(const std::vector<TlSegment>& segs, const TlPlan& plan, Ticks t,
                                                               bool accurate) {
  std::vector<QFrame> out;
  if (segs.empty()) {
    out.push_back({t, VideoFrame{}});
    cur_seg_ = 0;
    return out;
  }
  // At (or past) the end, show the last picture.
  if (t >= segs.back().end) t = std::max<Ticks>(segs.back().start, segs.back().end - 1);
  size_t i = 0;
  while (i + 1 < segs.size() && segs[i].end <= t) ++i;
  cur_seg_ = i;
  const TlSegment& seg = segs[i];
  if (!seg.clip) {
    out.push_back({t, VideoFrame{}});
    return out;
  }
  const TlClip& c = *seg.clip;
  ActiveVideo& a = video_for(c, plan);
  a.dec->seek(c.src_in + (t - c.start), accurate);
  VideoFrame f;
  if (a.dec->next(f)) {
    // Shown from t on (an accurate frame starts at or before t).
    const Ticks ft = to_timeline(c, f.pts);
    a.last_pts = std::max(seg.start, ft);
    out.push_back({t, std::move(f)});
  } else {
    out.push_back({t, VideoFrame{}});
  }
  return out;
}

std::vector<TimelinePlayer::QFrame> TimelinePlayer::video_next(const std::vector<TlSegment>& segs, const TlPlan& plan) {
  std::vector<QFrame> out;
  if (cur_seg_ >= segs.size()) return out;
  const TlSegment& seg = segs[cur_seg_];
  if (seg.clip && !seg.clip->still) {
    ActiveVideo& a = video_for(*seg.clip, plan);
    if (a.last_pts < 0) {
      // A decoder opened again (e.g. after an error): position it first.
      a.dec->seek(seg.clip->src_in + (seg.start - seg.clip->start), true);
      a.last_pts = seg.start - 1;
    }
    VideoFrame f;
    if (a.dec->next(f)) {
      const Ticks t = to_timeline(*seg.clip, f.pts);
      if (t < seg.end) {
        if (t > a.last_pts) {
          a.last_pts = t;
          out.push_back({t, std::move(f)});
        }
        return out;  // (a frame at or before the last one is skipped)
      }
      a.last_pts = t;
    }
  }
  // This segment is over (end reached, end of the file, a photo or a gap).
  return enter_segment(segs, plan, cur_seg_ + 1);
}

void TimelinePlayer::video_loop() {
  std::unique_lock<std::mutex> lock(mu_);
  while (!quit_) {
    cv_.wait(lock, [&] {
      return quit_ || vseek_pending_ ||
             (!video_eof_ && queue_.size() < static_cast<size_t>(opts_.video_queue_frames) && queue_bytes_locked() < opts_.video_queue_bytes);
    });
    if (quit_) break;
    const bool do_seek = vseek_pending_;
    const Ticks target = vseek_target_;
    const bool accurate = vseek_accurate_;
    vseek_pending_ = false;
    const uint64_t gen = generation_;
    auto plan = plan_;
    auto segs = segments_;
    lock.unlock();
    std::vector<QFrame> frames;
    std::string err;
    bool end = false;
    try {
      if (plan->composite) {
        active_.clear();
        frames = do_seek ? comp_seek(*plan, target) : comp_next(*plan);
      } else {
        comp_.reset();
        frames = do_seek ? video_seek(*segs, *plan, target, accurate) : video_next(*segs, *plan);
      }
      end = frames.empty();
    } catch (const std::bad_alloc&) {
      err = "out of memory while decoding video";
    } catch (const std::exception& e) {
      err = e.what();
    } catch (...) {
      err = "unknown video decoding error";
    }
    if (!err.empty()) {
      diag::note("timeline video: %s (segment skipped)", err.c_str());
      // Skip the broken segment: black from its start, continue after it.
      frames.clear();
      active_.clear();
      if (plan->composite) {
        // Black for this frame; the next one is tried again.
        frames.push_back({frames_to_ticks(comp_n_, plan->fps), VideoFrame{}});
        ++comp_n_;
        if (comp_) comp_->invalidate();
      } else {
        if (cur_seg_ < segs->size()) frames.push_back({(*segs)[cur_seg_].start, VideoFrame{}});
        ++cur_seg_;
      }
    }
    std::string decoder;
    bool hw = false;
    if (comp_) {
      decoder = comp_->pool().decoder_name();
      hw = comp_->pool().hardware();
    } else if (!active_.empty() && active_.back().dec) {
      decoder = active_.back().dec->decoder_name();
      hw = active_.back().dec->hardware();
    }
    lock.lock();
    if (!err.empty()) video_error_ = err;
    video_decoder_ = decoder;
    video_hw_ = hw;
    if (gen != generation_) continue;  // a newer seek arrived meanwhile
    for (auto& f : frames) {
      queue_.push_back(std::move(f));
      ++frames_decoded_;
    }
    if (end) video_eof_ = true;
  }
}

// ------------------------------------------------------- composed pictures

void TimelinePlayer::comp_ensure(const TlPlan& plan) {
  // The project frame inside the preview size (the preview quality setting
  // lowers it; the export always composes at the output size).
  int cw = plan.canvas_w > 0 ? plan.canvas_w : 1920, ch = plan.canvas_h > 0 ? plan.canvas_h : 1080;
  int max_w = opts_.max_width, max_h = opts_.max_height;
  if (plan.preview_height > 0) {
    max_h = std::min(max_h > 0 ? max_h : plan.preview_height, plan.preview_height);
    max_w = std::min(max_w > 0 ? max_w : max_h * 16 / 9, (max_h * 16 + 8) / 9);
  }
  double scale = 1;
  if (max_w > 0) scale = std::min(scale, static_cast<double>(max_w) / cw);
  if (max_h > 0) scale = std::min(scale, static_cast<double>(max_h) / ch);
  const int w = std::max(16, static_cast<int>(std::lround(cw * scale)) & ~1);
  const int h = std::max(16, static_cast<int>(std::lround(ch * scale)) & ~1);
  if (!comp_ || comp_->width() != w || comp_->height() != h) {
    DecodeOptions o;
    o.prefer_hardware = plan.hardware;
    comp_ = std::make_unique<Compositor>(w, h, o);
  }
}

TimelinePlayer::QFrame TimelinePlayer::comp_frame(Ticks t, bool black) {
  QFrame q;
  q.pts = t;
  if (!black) {
    const RgbaBuffer& p = comp_->picture();
    q.frame.width = p.w;
    q.frame.height = p.h;
    q.frame.pts = t;
    q.frame.rgba = p.px;
  }
  comp_last_push_ = t;
  return q;
}

std::vector<TimelinePlayer::QFrame> TimelinePlayer::comp_seek(const TlPlan& plan, Ticks t) {
  comp_ensure(plan);
  comp_->invalidate();
  if (plan.duration > 0 && t >= plan.duration) t = std::max<Ticks>(0, plan.duration - 1);
  bool black = false;
  comp_->render(plan, t, &black);
  comp_n_ = ticks_to_frames(t, plan.fps) + 1;
  return {comp_frame(t, black)};
}

std::vector<TimelinePlayer::QFrame> TimelinePlayer::comp_next(const TlPlan& plan) {
  comp_ensure(plan);
  // The next grid frame that differs (a still picture is queued again
  // every 0.25 s so the queue keeps moving).
  for (;;) {
    const Ticks t = frames_to_ticks(comp_n_, plan.fps);
    if (t >= plan.duration) return {};
    ++comp_n_;
    bool black = false;
    const bool changed = comp_->render(plan, t, &black);
    if (changed || t - comp_last_push_ >= kTicksPerSecond / 4) {
      return {comp_frame(t, black)};
    }
  }
}

// ------------------------------------------------------------ mixer thread

void TimelinePlayer::mix_loop() {
  constexpr size_t kBlock = 1024;
  std::vector<float> buf(kBlock * kMixChannels);
  std::vector<float> peaks;
  std::unique_lock<std::mutex> lock(mu_);
  while (!quit_) {
    cv_.wait(lock, [&] {
      if (quit_ || aseek_pending_) return true;
      // With a device the ring is kept full even while paused, so playback
      // starts with sound at once (no underrun at the first callback).
      if (audio_device_ok_) return ring_.size() + buf.size() <= ring_capacity_;
      if (!playing_) return false;
      // Without a device nobody drains the ring: mix just ahead of the clock
      // (for the meters), at most 0.2 s.
      return mix_pos_ < ticks_to_samples(position_locked()) + kMixRate / 5;
    });
    if (quit_) break;
    if (aseek_pending_) {
      aseek_pending_ = false;
      mix_pos_ = ticks_to_samples(paused_at_);
      ring_.clear();
      continue;
    }
    if (!audio_device_ok_ && mix_pos_ < ticks_to_samples(position_locked()) - kMixRate) {
      mix_pos_ = ticks_to_samples(position_locked());  // fell behind a steady clock: catch up
    }
    const int64_t pos = mix_pos_;
    const uint64_t gen = generation_;
    auto plan = plan_;
    lock.unlock();
    peaks.assign(plan->tracks.size() + 1, 0.0f);
    const auto t0 = Clock::now();
    try {
      mixer_.render(*plan, pos, kBlock, buf.data(), peaks.data(), &peaks.back());
    } catch (const std::exception& e) {
      std::fill(buf.begin(), buf.end(), 0.0f);
      diag::note("timeline mixer: %s", e.what());
    } catch (...) {
      std::fill(buf.begin(), buf.end(), 0.0f);
    }
    const auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - t0).count();
    lock.lock();
    if (gen != generation_) continue;
    mix_ns_ += ns;
    mixed_samples_ += static_cast<int64_t>(kBlock);
    if (audio_device_ok_) ring_.insert(ring_.end(), buf.begin(), buf.end());
    level_hist_.push_back({pos, peaks});
    while (level_hist_.size() > 48) level_hist_.pop_front();
    mix_pos_ = pos + static_cast<int64_t>(kBlock);
  }
}

void TimelinePlayer::audio_callback(float* out, uint32_t frames) {
  const size_t want = static_cast<size_t>(frames) * kMixChannels;
  std::unique_lock<std::mutex> lock(mu_, std::try_to_lock);
  if (!lock.owns_lock() || !playing_) {
    std::memset(out, 0, want * sizeof(float));
    return;
  }
  const size_t have = std::min(want, ring_.size());
  std::copy(ring_.begin(), ring_.begin() + static_cast<std::ptrdiff_t>(have), out);
  ring_.erase(ring_.begin(), ring_.begin() + static_cast<std::ptrdiff_t>(have));
  if (have < want) {
    std::memset(out + have, 0, (want - have) * sizeof(float));
    const Ticks now = base_ + mul_div(consumed_, kTicksPerSecond, kMixRate, Rounding::Down);
    if (now < plan_->duration) ++underruns_;
  }
  // Time moves on by what was played; at an underrun the clock still moves
  // (silence is played), so a slow mixer cannot freeze the picture.
  consumed_ += static_cast<int64_t>(frames);
  play_samples_at_start_ += static_cast<int64_t>(frames);
  last_callback_ = Clock::now();
  lock.unlock();
  cv_.notify_all();
}

// ---------------------------------------------------------- prepare thread

void TimelinePlayer::prepare_loop() {
  std::unique_lock<std::mutex> lock(mu_);
  while (!quit_) {
    cv_.wait_for(lock, std::chrono::milliseconds(100));
    if (quit_) break;
    const Ticks now = position_locked();
    auto plan = plan_;
    auto segs = segments_;
    // Next picture segment with a clip starting within 2 s.
    const TlSegment* next = nullptr;
    for (const auto& s : *segs) {
      if (s.start > now && s.start <= now + 2 * kTicksPerSecond && s.clip) {
        next = &s;
        break;
      }
    }
    const bool need_video = next && !plan->composite && !(prepared_.key == video_key(*next->clip) && prepared_.seg_start == next->start);
    const uint64_t gen = generation_;
    lock.unlock();
    try {
      mixer_.prepare(*plan, ticks_to_samples(now), 3LL * kMixRate);
    } catch (...) {
      // Opening is retried by the mixer itself when the clip is reached.
    }
    if (need_video) {
      PreparedVideo p;
      const TlClip& c = *next->clip;
      p.key = video_key(c);
      p.seg_start = next->start;
      try {
        p.dec = open_video(c, *plan);
        p.dec->seek(c.src_in + (next->start - c.start), true);
        p.has_first = p.dec->next(p.first);
      } catch (const std::exception& e) {
        diag::note("timeline: could not prepare the next clip (%s)", e.what());
        p = PreparedVideo{};
      }
      lock.lock();
      if (gen == generation_ && p.dec) prepared_ = std::move(p);
      continue;
    }
    lock.lock();
  }
}

// ------------------------------------------------------------------ output

bool TimelinePlayer::frame(uint64_t* serial, uint8_t* dst, size_t capacity, int* w, int* h, Ticks* pts) {
  bool stop_device = false;
  std::unique_lock<std::mutex> lock(mu_);
  const bool was_playing = playing_;
  update_end_locked();
  stop_device = was_playing && !playing_;
  const Ticks now = position_locked();
  bool changed = false;
  int consumed = 0;
  while (!queue_.empty()) {
    const bool need_first = !has_current_ || current_generation_ != generation_;
    if (!need_first && queue_.front().pts > now) break;
    current_ = std::move(queue_.front());
    queue_.pop_front();
    has_current_ = true;
    current_generation_ = generation_;
    changed = true;
    ++consumed;
    if (need_first && !playing_) break;  // paused after a seek: exactly the seek frame
  }
  if (consumed > 1) frames_dropped_ += consumed - 1;
  if (changed) {
    ++current_serial_;
    ++frames_shown_;
    if (playing_) {
      const double late = static_cast<double>(now - current_.pts) * 1000.0 / static_cast<double>(kTicksPerSecond);
      late_sum_ms_ += late;
      late_max_ms_ = std::max(late_max_ms_, late);
      ++late_count_;
    }
  }
  bool copied = false;
  if (has_current_ && serial && *serial != current_serial_) {
    const size_t need = current_.frame.rgba.size();
    if (w) *w = current_.frame.width;
    if (h) *h = current_.frame.height;
    if (pts) *pts = current_.pts;
    if (need == 0) {
      if (w) *w = 0;
      if (h) *h = 0;
      *serial = current_serial_;
      copied = true;
    } else if (dst && capacity >= need) {
      std::memcpy(dst, current_.frame.rgba.data(), need);
      *serial = current_serial_;
      copied = true;
    }
  }
  lock.unlock();
  if (changed) cv_.notify_all();
  if (stop_device && out_) out_->stop();
  return copied;
}

size_t TimelinePlayer::levels(float* out, size_t capacity) const {
  std::lock_guard<std::mutex> lock(mu_);
  const size_t n = plan_->tracks.size() + 1;
  const size_t m = std::min(n, capacity);
  std::fill(out, out + m, 0.0f);
  if (!playing_) return m;
  // Blocks heard in the last ~50 ms.
  const int64_t now = ticks_to_samples(position_locked());
  for (const auto& b : level_hist_) {
    if (b.pos + 1024 < now - kMixRate / 20 || b.pos > now) continue;
    for (size_t i = 0; i < m && i < b.peaks.size(); ++i) out[i] = std::max(out[i], b.peaks[i]);
  }
  return m;
}

std::string TimelinePlayer::stats_json() const {
  std::lock_guard<std::mutex> lock(mu_);
  JsonWriter j;
  j.begin_object();
  j.key("positionTicks").value(position_locked());
  j.key("durationTicks").value(plan_->duration);
  j.key("playing").value(playing_);
  j.key("audioDevice").value(audio_device_ok_);
  j.key("audioBackend").value(out_ ? out_->backend() : "none");
  j.key("audioLatencyMs").value(out_ ? static_cast<double>(out_->latency()) * 1000.0 / kTicksPerSecond : 0.0);
  j.key("audioBufferedMs").value(static_cast<double>(ring_.size() / kMixChannels) * 1000.0 / kMixRate);
  j.key("audioUnderruns").value(underruns_);
  j.key("clippedSamples").value(mixer_.clipped_samples());
  j.key("audioDecoders").value(static_cast<int64_t>(mixer_.decoders_open()));
  j.key("mixLoadPercent").value(mixed_samples_ > 0 ? static_cast<double>(mix_ns_) / 1e9 / (static_cast<double>(mixed_samples_) / kMixRate) * 100.0
                                                   : 0.0);
  // Audio clock against the wall clock since playback started (device rate).
  double drift = 0.0;
  if (playing_ && audio_device_ok_) {
    const double wall = std::chrono::duration<double>(Clock::now() - play_wall_start_).count();
    const double audio = static_cast<double>(play_samples_at_start_) / kMixRate;
    drift = (audio - wall) * 1000.0;
  }
  j.key("audioClockDriftMs").value(drift);
  j.key("framesShown").value(frames_shown_);
  j.key("framesDropped").value(frames_dropped_);
  j.key("framesDecoded").value(frames_decoded_);
  j.key("videoLateAvgMs").value(late_count_ ? late_sum_ms_ / static_cast<double>(late_count_) : 0.0);
  j.key("videoLateMaxMs").value(late_max_ms_);
  j.key("clipTransitions").value(transitions_);
  j.key("preparedTransitions").value(prepared_hits_);
  j.key("queuedFrames").value(static_cast<int64_t>(queue_.size()));
  j.key("decoder").value(video_decoder_);
  j.key("hardware").value(video_hw_);
  j.key("videoError").value(video_error_);
  j.key("audioError").value(mixer_.last_error());
  int64_t rss = 0, peak = 0;
  diag::memory_kib(&rss, &peak);
  j.key("rssKiB").value(rss);
  j.end_object();
  return j.str();
}

}  // namespace cutlab::media
