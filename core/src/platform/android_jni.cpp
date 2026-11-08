// Android: registers the Java VM with FFmpeg so the MediaCodec hardware
// decoders can be used. Runs when MainActivity calls
// System.loadLibrary("cutlab_core") (dart:ffi's dlopen alone does not call it).
#include <jni.h>

extern "C" {
#include <libavcodec/jni.h>
}

extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
  av_jni_set_java_vm(vm, nullptr);
  return JNI_VERSION_1_6;
}
