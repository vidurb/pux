#include "test_harness.hpp"
#include <glib.h>
#include <cstdlib>

int main(int /*argc*/, char** /*argv*/) {
#if defined(__linux__)
    setenv("PUX_LINUX_TEST_NO_NETWORK", "1", 1);
#endif
    return pux::test::TestRegistry::instance().run_all();
}
