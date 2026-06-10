/* Weak __asan_default_options baked into the sanitized matio_fuzzer binary.
 *
 * matio's parser (mat4.c/mat5.c/mat73.c/read_data.c) allocates per-variable buffers as it walks a
 * .mat file. On MALFORMED inputs the parser returns early on many error paths without freeing every
 * partially-read buffer, so ASan's default leak detection would fire on a large fraction of fuzz
 * inputs and bury the real memory-safety bugs (heap/stack/global OOB, use-after-free) in the parsing
 * code. Disable leak detection (detect_leaks=0) while keeping all of ASan's other checks ON and
 * halting. Linked as a weak symbol, so it is a default still overridable at runtime if ever needed.
 *
 * NOTE: we do NOT set ASAN_OPTIONS in the Mayhemfile (Mayhem owns the runtime option set); baking the
 * default into the binary is the supported way to turn leak detection off for fuzzing.
 */
const char *__asan_default_options(void) {
    return "detect_leaks=0";
}
