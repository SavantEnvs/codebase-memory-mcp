# Parallel, incremental object-per-file build of the fuzz binaries and the test runner, reusing the
# project's own flags, sources and vendored-object rules from Makefile.cbm (upstream compiles every
# source in one serial compiler call, which takes >10 minutes). Invoked by mayhem/build.sh from the
# repo root with BUILD_DIR, CC, CXX and SANITIZE set on the command line.
include Makefile.cbm

LIB_SRCS = $(PROD_SRCS) $(EXTRACTION_SRCS) $(AC_LZ4_SRCS) $(ZSTD_SRCS) $(SQLITE_WRITER_SRC)
LIB_OBJS = $(patsubst %.c,$(BUILD_DIR)/obj/%.o,$(LIB_SRCS))
TEST_OBJS = $(patsubst %.c,$(BUILD_DIR)/obj/%.o,$(ALL_TEST_SRCS))
FUZZ_OBJ = $(BUILD_DIR)/obj/tests/fuzz/cbm_fuzz.o

$(LIB_OBJS) $(FUZZ_OBJ): $(BUILD_DIR)/obj/%.o: %.c $(PROJECT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_TEST) -c -o $@ $<

$(TEST_OBJS): $(BUILD_DIR)/obj/%.o: %.c $(PROJECT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_TEST) -Itests -Itests/repro -c -o $@ $<

mayhem-fuzz: $(FUZZ_OBJ) $(LIB_OBJS) $(OBJS_VENDORED_TEST)
	$(CC) $(CFLAGS_TEST) $(LIB_FUZZING_ENGINE) -fsanitize-link-c++-runtime -o $(MAYHEM_FUZZ_OUT) \
		$(FUZZ_OBJ) $(LIB_OBJS) $(OBJS_VENDORED_TEST) $(MAYHEM_LSAN_OBJ) $(LDFLAGS_TEST)

mayhem-standalone: $(FUZZ_OBJ) $(LIB_OBJS) $(OBJS_VENDORED_TEST)
	$(CC) $(CFLAGS_TEST) -fsanitize-link-c++-runtime -o $(MAYHEM_STANDALONE_OUT) \
		$(FUZZ_OBJ) $(MAYHEM_STANDALONE_MAIN_OBJ) $(LIB_OBJS) $(OBJS_VENDORED_TEST) $(MAYHEM_LSAN_OBJ) $(LDFLAGS_TEST)

mayhem-test-runner: $(TEST_OBJS) $(LIB_OBJS) $(OBJS_VENDORED_TEST)
	$(CC) $(CFLAGS_TEST) -fsanitize-link-c++-runtime -o $(BUILD_DIR)/cbm-test-runner \
		$(TEST_OBJS) $(LIB_OBJS) $(OBJS_VENDORED_TEST) $(LDFLAGS_TEST)

.PHONY: mayhem-fuzz mayhem-standalone mayhem-test-runner
