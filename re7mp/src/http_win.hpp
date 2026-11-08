#pragma once
// HttpClient over WinHTTP (part of Windows, no extra DLLs). Windows only; the exe's GUI uses it, the tests use a fake.
#include <memory>
#include <string>

#include "updater.hpp"

namespace re7mp {

std::unique_ptr<HttpClient> make_winhttp_client(const std::string& user_agent);

}  // namespace re7mp
