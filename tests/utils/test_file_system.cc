/** Copyright 2020 Alibaba Group Holding Limited.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * 	http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <chrono>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>

#include <gtest/gtest.h>

#include "glob/glob/glob.hpp"
#include "neug/utils/io/read/common/schema.h"
#include "neug/utils/io/vfs/file_system.h"

namespace neug::test {
namespace {

class TaggedFileSystem final : public fsys::FileSystem {
 public:
  explicit TaggedFileSystem(std::string tag) : tag_(std::move(tag)) {}

  std::vector<std::string> glob(const std::string&) override { return {tag_}; }

 private:
  std::string tag_;
};

class PortableGlobTest : public ::testing::Test {
 protected:
  void SetUp() override {
    directory_ =
        std::filesystem::temp_directory_path() /
        ("neug_glob_" +
         std::to_string(
             std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(directory_ / "sub");
    for (const auto* name : {"a.csv", "b.csv", ".hidden.csv", "sub/c.csv"}) {
      std::ofstream(directory_ / name) << "1\n";
    }
  }

  void TearDown() override { std::filesystem::remove_all(directory_); }

  std::filesystem::path directory_;
};

// The implementation shared by Android API 24-27 and Windows must exclude
// hidden files from ordinary import patterns.
TEST_F(PortableGlobTest, FilePatternsAndHiddenFiles) {
  auto match = [this](const char* pattern) {
    return glob::glob((directory_ / pattern).string());
  };
  EXPECT_EQ(match("*.csv").size(), 2);
  EXPECT_EQ(match("?.csv").size(), 2);
  const auto hidden = match(".*.csv");
  ASSERT_EQ(hidden.size(), 1);
  EXPECT_EQ(hidden.front().filename(), ".hidden.csv");
  EXPECT_EQ(match("sub*/*.csv").size(), 1);
  EXPECT_TRUE(match("missing*.csv").empty());
  EXPECT_TRUE(match("absent/*.csv").empty());
}

TEST(FileSystemRegistry, DuplicateRegistrationKeepsExistingFactory) {
  fsys::FileSystemRegistry registry;
  ASSERT_TRUE(registry.Register("replay-safe", [](const reader::FileSchema&) {
    return std::make_unique<TaggedFileSystem>("first");
  }));
  EXPECT_FALSE(registry.Register("replay-safe", [](const reader::FileSchema&) {
    return std::make_unique<TaggedFileSystem>("second");
  }));

  reader::FileSchema schema;
  schema.protocol = "replay-safe";
  auto file_system = registry.Provide(schema);
  EXPECT_EQ(file_system->glob("unused"), std::vector<std::string>({"first"}));
}

}  // namespace
}  // namespace neug::test
