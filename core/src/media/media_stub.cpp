// Media API when the core is built without FFmpeg (CUTLAB_WITH_MEDIA=OFF):
// every call reports CUTLAB_ERR_UNAVAILABLE so callers can degrade gracefully.
#include "cutlab/cutlab_core.h"

extern "C" {

const char* cutlab_last_error(void) { return "media engine not built"; }
void cutlab_free(void*) {}
void cutlab_close_fd(int32_t) {}
cutlab_status cutlab_engine_info(char**) { return CUTLAB_ERR_UNAVAILABLE; }
cutlab_status cutlab_media_probe(const char*, char**) { return CUTLAB_ERR_UNAVAILABLE; }
cutlab_status cutlab_media_frame(const char*, int64_t, int32_t, int32_t, int32_t, uint8_t**, int32_t*, int32_t*, int64_t*) {
  return CUTLAB_ERR_UNAVAILABLE;
}
cutlab_status cutlab_media_thumbnails(const char*, int32_t, int32_t, int32_t, uint8_t**, int32_t*, int32_t*, int32_t*, int64_t*) {
  return CUTLAB_ERR_UNAVAILABLE;
}
cutlab_status cutlab_media_peaks(const char*, int32_t, const volatile int32_t*, volatile int32_t*, float**, int64_t*) {
  return CUTLAB_ERR_UNAVAILABLE;
}
cutlab_status cutlab_player_open(const char*, int32_t, int32_t, int32_t, cutlab_player**) { return CUTLAB_ERR_UNAVAILABLE; }
void cutlab_player_close(cutlab_player*) {}
void cutlab_player_play(cutlab_player*) {}
void cutlab_player_pause(cutlab_player*) {}
int32_t cutlab_player_playing(cutlab_player*) { return 0; }
void cutlab_player_seek(cutlab_player*, int64_t, int32_t) {}
int64_t cutlab_player_position(cutlab_player*) { return 0; }
int64_t cutlab_player_duration(cutlab_player*) { return 0; }
int32_t cutlab_player_frame(cutlab_player*, uint64_t*, uint8_t*, int64_t, int32_t*, int32_t*, int64_t*) { return 0; }
cutlab_status cutlab_player_stats(cutlab_player*, char**) { return CUTLAB_ERR_UNAVAILABLE; }
cutlab_status cutlab_hw_self_test(const char*, char**) { return CUTLAB_ERR_UNAVAILABLE; }
cutlab_status cutlab_diag_init(const char*, const char*) { return CUTLAB_ERR_UNAVAILABLE; }
void cutlab_diag_note(const char*) {}
cutlab_status cutlab_diag_recent(char**) { return CUTLAB_ERR_UNAVAILABLE; }

}  // extern "C"
