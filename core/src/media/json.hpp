// Tiny JSON writer for results handed to Dart (internal header).
#pragma once

#include <cstdint>
#include <cstdio>
#include <string>

namespace cutlab::media {

class JsonWriter {
 public:
  JsonWriter& begin_object() { sep(); out_ += '{'; first_ = true; return *this; }
  JsonWriter& end_object() { out_ += '}'; first_ = false; return *this; }
  JsonWriter& begin_array() { sep(); out_ += '['; first_ = true; return *this; }
  JsonWriter& end_array() { out_ += ']'; first_ = false; return *this; }

  JsonWriter& key(const char* k) {
    sep();
    write_string(k);
    out_ += ':';
    after_key_ = true;
    return *this;
  }

  JsonWriter& value(const std::string& s) { sep(); write_string(s); return *this; }
  JsonWriter& value(const char* s) { return value(std::string(s ? s : "")); }
  JsonWriter& value(bool b) { sep(); out_ += b ? "true" : "false"; return *this; }
  JsonWriter& value(int v) { return value(static_cast<int64_t>(v)); }
  JsonWriter& value(int64_t v) { sep(); out_ += std::to_string(v); return *this; }
  JsonWriter& value(double v) {
    sep();
    char buf[32];
    std::snprintf(buf, sizeof buf, "%.6g", v);
    out_ += buf;
    return *this;
  }
  JsonWriter& null() { sep(); out_ += "null"; return *this; }

  const std::string& str() const { return out_; }

 private:
  void sep() {
    if (after_key_) {
      after_key_ = false;
      return;
    }
    if (!first_) out_ += ',';
    first_ = false;
  }

  void write_string(const std::string& s) {
    out_ += '"';
    for (const char c : s) {
      switch (c) {
        case '"': out_ += "\\\""; break;
        case '\\': out_ += "\\\\"; break;
        case '\n': out_ += "\\n"; break;
        case '\r': out_ += "\\r"; break;
        case '\t': out_ += "\\t"; break;
        default:
          if (static_cast<unsigned char>(c) < 0x20) {
            char buf[8];
            std::snprintf(buf, sizeof buf, "\\u%04x", c);
            out_ += buf;
          } else {
            out_ += c;
          }
      }
    }
    out_ += '"';
  }

  std::string out_;
  bool first_ = true;
  bool after_key_ = false;
};

}  // namespace cutlab::media
