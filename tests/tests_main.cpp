/**
 * @file tests/tests_main.cpp
 * @brief Entry point definition.
 */
#include "tests_common.h"
#include "tests_environment.h"
#include "tests_events.h"

int main(int argc, char **argv) {
  testing::InitGoogleTest(&argc, argv);
  testing::AddGlobalTestEnvironment(new PrismEnvironment);
  testing::UnitTest::GetInstance()->listeners().Append(new PrismEventListener);
  return RUN_ALL_TESTS();
}
