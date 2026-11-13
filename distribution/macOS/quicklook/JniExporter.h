#ifndef JNI_EXPORTER_H
#define JNI_EXPORTER_H

#ifdef __cplusplus
extern "C" {
#endif

int jni_export_circuit_svg(const char *jvm_dylib_path, const char *jar_path, const char *dig_path, const char *svg_path, char *err_buf, int err_buf_len);

#ifdef __cplusplus
}
#endif

#endif // JNI_EXPORTER_H
