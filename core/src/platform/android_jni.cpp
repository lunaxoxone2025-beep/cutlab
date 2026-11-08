// Android JNI entry points.
//
// JNI_OnLoad registers the Java VM with FFmpeg so the MediaCodec hardware
// decoders can be used. It runs when Java/Kotlin calls
// System.loadLibrary("cutlab_core") (dart:ffi's dlopen alone does not).
#include <jni.h>

#include <string>

#include "cutlab/cutlab_core.h"

extern "C" {
#include <libavcodec/jni.h>
}

extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
  av_jni_set_java_vm(vm, nullptr);
  return JNI_VERSION_1_6;
}

// HwProbeNative.nativeSelfTest(String uri): runs cutlab_hw_self_test in the
// separate ":hwprobe" process. A crash there ends only that process.
extern "C" JNIEXPORT jstring JNICALL Java_com_lunaxoxone_studio_cutlab_HwProbeNative_nativeSelfTest(JNIEnv* env, jclass /*cls*/,
                                                                                                  jstring juri) {
  const char* uri = env->GetStringUTFChars(juri, nullptr);
  std::string result;
  char* json = nullptr;
  if (cutlab_hw_self_test(uri, &json) == CUTLAB_OK && json) {
    result = json;
    cutlab_free(json);
  } else {
    std::string err = cutlab_last_error();
    std::string esc;
    for (char c : err) {
      if (c == '"' || c == '\\') esc += '\\';
      if (static_cast<unsigned char>(c) >= 0x20) esc += c;
    }
    result = "{\"ok\":false,\"error\":\"" + esc + "\"}";
  }
  env->ReleaseStringUTFChars(juri, uri);
  return env->NewStringUTF(result.c_str());
}

// HwProbeNative.nativeEncoderTest(): the encoder list with every hardware
// (MediaCodec) encoder test-encoded, in the ":hwprobe" process.
extern "C" JNIEXPORT jstring JNICALL Java_com_lunaxoxone_studio_cutlab_HwProbeNative_nativeEncoderTest(JNIEnv* env, jclass /*cls*/) {
  std::string result;
  char* json = nullptr;
  if (cutlab_export_encoders(1, &json) == CUTLAB_OK && json) {
    result = std::string("{\"encoders\":") + json + "}";
    cutlab_free(json);
  } else {
    result = "{\"error\":\"the encoder test failed\"}";
  }
  return env->NewStringUTF(result.c_str());
}
