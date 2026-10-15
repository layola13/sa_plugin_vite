#include <stddef.h>
#include <stdlib.h>
#include <string.h>

static char *sa_llvmc_stub_error(void) {
    const char *message = "LLVM-C backend is disabled in this build";
    size_t len = strlen(message) + 1;
    char *out = (char *)malloc(len);
    if (out == 0) return 0;
    memcpy(out, message, len);
    return out;
}

void sa_llvmc_free(void *ptr) { free(ptr); }

int sa_llvmc_make_minimal_module_bitcode(unsigned char **out_bytes, size_t *out_len, char **out_error) {
    if (out_bytes != 0) *out_bytes = 0;
    if (out_len != 0) *out_len = 0;
    if (out_error != 0) *out_error = sa_llvmc_stub_error();
    return 1;
}

int sa_llvmc_emit_module_bitcode(const void *module, int opt_level, unsigned char **out_bytes, size_t *out_len, char **out_error) {
    (void)module;
    (void)opt_level;
    if (out_bytes != 0) *out_bytes = 0;
    if (out_len != 0) *out_len = 0;
    if (out_error != 0) *out_error = sa_llvmc_stub_error();
    return 1;
}

int sa_llvmc_emit_module_object(const void *module, const char *out_path, int opt_level, char **out_error) {
    (void)module;
    (void)out_path;
    (void)opt_level;
    if (out_error != 0) *out_error = sa_llvmc_stub_error();
    return 1;
}

int sa_llvmc_emit_module_artifacts(const void *module, const char *out_bitcode_path, const char *out_object_path, int opt_level, char **out_error) {
    (void)module;
    (void)out_bitcode_path;
    (void)out_object_path;
    (void)opt_level;
    if (out_error != 0) *out_error = sa_llvmc_stub_error();
    return 1;
}
