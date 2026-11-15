#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <pwd.h>
#include "include/jni.h"

typedef jint (*JNI_CreateJavaVM_t)(JavaVM **, void **, void *);
typedef jint (*JNI_GetCreatedJavaVMs_t)(JavaVM **, jsize, jsize *);

static JavaVM *g_jvm = NULL;
static void *g_libjvm = NULL;
static jclass g_svgExportClass = NULL;
static jmethodID g_runHeadlessMid = NULL;
static jclass g_stringClass = NULL;

int jni_export_circuit_svg(const char *jvm_dylib_path, const char *jar_path, const char *dig_path, const char *svg_path, char *err_buf, int err_buf_len) {
    if (!jvm_dylib_path || !jar_path || !dig_path || !svg_path) {
        if (err_buf) snprintf(err_buf, err_buf_len, "Invalid arguments passed to jni_export_circuit_svg");
        return -1;
    }

    if (access(dig_path, R_OK) != 0) {
        if (err_buf) snprintf(err_buf, err_buf_len, "Cannot access .dig file at: %s", dig_path);
        return -4;
    }

    if (!g_jvm) {
        if (access(jvm_dylib_path, R_OK) != 0) {
            if (err_buf) snprintf(err_buf, err_buf_len, "Cannot access libjvm at: %s", jvm_dylib_path);
            return -2;
        }
        if (access(jar_path, R_OK) != 0) {
            if (err_buf) snprintf(err_buf, err_buf_len, "Cannot access Digital.jar at: %s", jar_path);
            return -3;
        }

        if (!g_libjvm) {
            g_libjvm = dlopen(jvm_dylib_path, RTLD_NOW | RTLD_GLOBAL);
            if (!g_libjvm) {
                if (err_buf) snprintf(err_buf, err_buf_len, "dlopen failed for %s: %s", jvm_dylib_path, dlerror());
                return -5;
            }
        }
    }

    JNIEnv *env = NULL;
    if (!g_jvm) {
        JNI_GetCreatedJavaVMs_t get_vms = (JNI_GetCreatedJavaVMs_t)dlsym(g_libjvm, "JNI_GetCreatedJavaVMs");
        jsize nVMs = 0;
        if (get_vms && get_vms(&g_jvm, 1, &nVMs) == JNI_OK && nVMs > 0 && g_jvm) {
            jint env_res = (*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_8);
            if (env_res == JNI_EDETACHED) {
                (*g_jvm)->AttachCurrentThread(g_jvm, (void **)&env, NULL);
            }
        } else {
            JNI_CreateJavaVM_t create_vm = (JNI_CreateJavaVM_t)dlsym(g_libjvm, "JNI_CreateJavaVM");
            if (!create_vm) {
                if (err_buf) snprintf(err_buf, err_buf_len, "dlsym JNI_CreateJavaVM failed: %s", dlerror());
                return -6;
            }

            char cp_opt[1024];
            snprintf(cp_opt, sizeof(cp_opt), "-Djava.class.path=%s", jar_path);

            char home_opt[1024] = "";
            struct passwd *pw = getpwuid(getuid());
            if (pw && pw->pw_dir) {
                snprintf(home_opt, sizeof(home_opt), "-Duser.home=%s", pw->pw_dir);
            }

            JavaVMOption options[10];
            int n_opts = 0;
            options[n_opts].optionString = cp_opt;
            options[n_opts++].extraInfo = NULL;
            options[n_opts].optionString = "-Djava.awt.headless=true";
            options[n_opts++].extraInfo = NULL;
            options[n_opts].optionString = "-Xms8m";
            options[n_opts++].extraInfo = NULL;
            options[n_opts].optionString = "-Xmx64m";
            options[n_opts++].extraInfo = NULL;
            options[n_opts].optionString = "-XX:+UseSerialGC";
            options[n_opts++].extraInfo = NULL;
            options[n_opts].optionString = "-XX:TieredStopAtLevel=1";
            options[n_opts++].extraInfo = NULL;
            options[n_opts].optionString = "-XX:-UsePerfData";
            options[n_opts++].extraInfo = NULL;
            if (home_opt[0] != '\0') {
                options[n_opts].optionString = home_opt;
                options[n_opts++].extraInfo = NULL;
            }

            JavaVMInitArgs vm_args;
            vm_args.version = JNI_VERSION_1_8;
            vm_args.nOptions = n_opts;
            vm_args.options = options;
            vm_args.ignoreUnrecognized = JNI_FALSE;

            jint res = create_vm(&g_jvm, (void **)&env, &vm_args);
            if (res != JNI_OK || !env) {
                if (err_buf) snprintf(err_buf, err_buf_len, "JNI_CreateJavaVM failed with code %d", res);
                return -7;
            }
        }
    } else {
        jint env_res = (*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_8);
        if (env_res == JNI_EDETACHED) {
            (*g_jvm)->AttachCurrentThread(g_jvm, (void **)&env, NULL);
        }
    }

    if (!env) {
        if (err_buf) snprintf(err_buf, err_buf_len, "Failed to get JNIEnv");
        return -8;
    }

    if (!g_svgExportClass || !g_runHeadlessMid) {
        jclass localCls = (*env)->FindClass(env, "de/neemann/digital/cli/SVGExport");
        if (!localCls) {
            (*env)->ExceptionDescribe(env);
            (*env)->ExceptionClear(env);
            if (err_buf) snprintf(err_buf, err_buf_len, "Class de.neemann.digital.cli.SVGExport not found");
            return -9;
        }

        g_runHeadlessMid = (*env)->GetStaticMethodID(env, localCls, "runHeadless", "([Ljava/lang/String;)I");
        if (!g_runHeadlessMid) {
            (*env)->ExceptionDescribe(env);
            (*env)->ExceptionClear(env);
            if (err_buf) snprintf(err_buf, err_buf_len, "Method runHeadless not found in SVGExport");
            return -10;
        }

        g_svgExportClass = (jclass)(*env)->NewGlobalRef(env, localCls);
        (*env)->DeleteLocalRef(env, localCls);
    }

    if (!g_stringClass) {
        jclass localStrCls = (*env)->FindClass(env, "java/lang/String");
        if (!localStrCls) {
            (*env)->ExceptionDescribe(env);
            (*env)->ExceptionClear(env);
            if (err_buf) snprintf(err_buf, err_buf_len, "Class java.lang.String not found");
            return -11;
        }
        g_stringClass = (jclass)(*env)->NewGlobalRef(env, localStrCls);
        (*env)->DeleteLocalRef(env, localStrCls);
    }

    jobjectArray args = (*env)->NewObjectArray(env, 2, g_stringClass, NULL);
    jstring inStr = (*env)->NewStringUTF(env, dig_path);
    jstring outStr = (*env)->NewStringUTF(env, svg_path);
    (*env)->SetObjectArrayElement(env, args, 0, inStr);
    (*env)->SetObjectArrayElement(env, args, 1, outStr);

    jint result = (*env)->CallStaticIntMethod(env, g_svgExportClass, g_runHeadlessMid, args);
    if ((*env)->ExceptionOccurred(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        if (err_buf) snprintf(err_buf, err_buf_len, "Exception occurred during runHeadless call");
        (*env)->DeleteLocalRef(env, inStr);
        (*env)->DeleteLocalRef(env, outStr);
        (*env)->DeleteLocalRef(env, args);
        return -12;
    }

    (*env)->DeleteLocalRef(env, inStr);
    (*env)->DeleteLocalRef(env, outStr);
    (*env)->DeleteLocalRef(env, args);

    if (result != 0) {
        if (err_buf) snprintf(err_buf, err_buf_len, "runHeadless returned error code: %d", result);
        return result;
    }

    return 0;
}
