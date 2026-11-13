#pragma once

#include <cstdlib>
#include <chrono>
#include <exception>
#include <future>
#include <iostream>
#include <string>
#include <thread>
#include <vector>
#include <functional>
#include <sstream>

namespace pux {
namespace test {

class TestSkippedException : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

struct TestCase {
    std::string name;
    std::function<void()> func;
};

class TestRegistry {
public:
    static TestRegistry& instance() {
        static TestRegistry reg;
        return reg;
    }

    void add_test(const std::string& name, std::function<void()> func) {
        tests_.push_back({name, std::move(func)});
    }

    static int per_test_timeout_seconds() {
        if (const char* env = std::getenv("PUX_TEST_TIMEOUT_SEC")) {
            const int value = std::atoi(env);
            return value > 0 ? value : 120;
        }
        return 120;
    }

    int run_all() {
        int passed = 0;
        int failed = 0;
        int skipped = 0;
        const bool require_all = std::getenv("PUX_REQUIRE_KEYRING") != nullptr;
        const auto timeout = std::chrono::seconds(per_test_timeout_seconds());
        std::cout << "Running " << tests_.size() << " tests...\n";
        std::cout << "========================================\n";

        for (const auto& t : tests_) {
            std::cout << "[ RUN      ] " << t.name << "\n";
            try {
                std::promise<void> done;
                std::exception_ptr failure;
                std::thread worker([&] {
                    try {
                        t.func();
                        done.set_value();
                    } catch (...) {
                        failure = std::current_exception();
                        done.set_value();
                    }
                });
                if (done.get_future().wait_for(timeout) != std::future_status::ready) {
                    worker.detach();
                    throw std::runtime_error(
                        "Test timed out after " + std::to_string(per_test_timeout_seconds()) + " seconds");
                }
                worker.join();
                if (failure) {
                    std::rethrow_exception(failure);
                }
                std::cout << "[       OK ] " << t.name << "\n";
                passed++;
            } catch (const TestSkippedException& e) {
                std::cout << "[  SKIPPED ] " << t.name << "\n";
                std::cout << "             Reason: " << e.what() << "\n";
                ++skipped;
            } catch (const std::exception& e) {
                std::cout << "[  FAILED  ] " << t.name << "\n";
                std::cout << "             Error: " << e.what() << "\n";
                failed++;
            } catch (...) {
                std::cout << "[  FAILED  ] " << t.name << "\n";
                std::cout << "             Error: Unknown exception\n";
                failed++;
            }
        }

        if (require_all && skipped > 0) {
            failed += skipped;
        }

        std::cout << "========================================\n";
        std::cout << "Total tests: " << tests_.size() << "\n";
        std::cout << "Passed:      " << passed << "\n";
        std::cout << "Skipped:     " << skipped << "\n";
        std::cout << "Failed:      " << failed << "\n";

        return failed == 0 ? 0 : 1;
    }

private:
    std::vector<TestCase> tests_;
};

struct TestRegistrar {
    TestRegistrar(const std::string& name, std::function<void()> func) {
        TestRegistry::instance().add_test(name, std::move(func));
    }
};

#define SKIP_TEST(reason) \
    throw pux::test::TestSkippedException(reason)

#define TEST(test_name) \
    static void test_name(); \
    static pux::test::TestRegistrar registrar_##test_name(#test_name, test_name); \
    static void test_name()

#define ASSERT_TRUE(cond) \
    do { \
        if (!(cond)) { \
            std::ostringstream oss; \
            oss << "Assertion failed: (" #cond ") at " << __FILE__ << ":" << __LINE__; \
            throw std::runtime_error(oss.str()); \
        } \
    } while (0)

#define ASSERT_FALSE(cond) ASSERT_TRUE(!(cond))

#define ASSERT_EQ(a, b) \
    do { \
        if (!((a) == (b))) { \
            std::ostringstream oss; \
            oss << "Assertion failed: (" #a " == " #b ") [ " << (a) << " != " << (b) << " ] at " << __FILE__ << ":" << __LINE__; \
            throw std::runtime_error(oss.str()); \
        } \
    } while (0)

#define ASSERT_NE(a, b) \
    do { \
        if ((a) == (b)) { \
            std::ostringstream oss; \
            oss << "Assertion failed: (" #a " != " #b ") [ " << (a) << " == " << (b) << " ] at " << __FILE__ << ":" << __LINE__; \
            throw std::runtime_error(oss.str()); \
        } \
    } while (0)

#define ASSERT_THROWS(expr, ExceptionType) \
    do { \
        bool caught = false; \
        try { \
            expr; \
        } catch (const ExceptionType&) { \
            caught = true; \
        } catch (...) {} \
        if (!caught) { \
            std::ostringstream oss; \
            oss << "Expected exception " #ExceptionType " for expression (" #expr ") at " << __FILE__ << ":" << __LINE__; \
            throw std::runtime_error(oss.str()); \
        } \
    } while (0)

} // namespace test
} // namespace pux
