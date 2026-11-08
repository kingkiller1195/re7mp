// WinHTTP implementation of HttpClient: HTTPS GET with redirects (GitHub sends release downloads to another host),
// system proxy settings, timeouts, a size cap, and plain-English errors.
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <winhttp.h>

#include <string>
#include <vector>

#include "http_win.hpp"

#pragma comment(lib, "winhttp.lib")

namespace re7mp {

namespace {

constexpr uint64_t kMaxDownload = 300ull * 1024 * 1024;

std::wstring widen_utf8(const std::string& s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0], n);
    return w;
}

struct Handle {
    HINTERNET h = nullptr;
    Handle() = default;
    explicit Handle(HINTERNET handle) : h(handle) {}
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    ~Handle() {
        if (h) WinHttpCloseHandle(h);
    }
};

std::string describe_error(DWORD code) {
    switch (code) {
        case ERROR_WINHTTP_TIMEOUT: return "the connection timed out";
        case ERROR_WINHTTP_NAME_NOT_RESOLVED: return "could not find github.com (no internet connection?)";
        case ERROR_WINHTTP_CANNOT_CONNECT:
        case ERROR_WINHTTP_CONNECTION_ERROR: return "could not connect (no internet connection, or a firewall is blocking re7mp.exe)";
        case ERROR_WINHTTP_SECURE_FAILURE: return "the secure connection failed (is your PC's date and time right?)";
        default: return "network error " + std::to_string(static_cast<unsigned long>(code));
    }
}

class WinHttpClient : public HttpClient {
public:
    explicit WinHttpClient(std::string user_agent) : agent_(widen_utf8(user_agent)) {}

    bool get(const std::string& url, std::vector<uint8_t>& body, std::string& err, const Progress& progress) override {
        body.clear();
        const std::wstring wurl = widen_utf8(url);

        URL_COMPONENTS uc{};
        uc.dwStructSize = sizeof(uc);
        uc.dwSchemeLength = static_cast<DWORD>(-1);
        uc.dwHostNameLength = static_cast<DWORD>(-1);
        uc.dwUrlPathLength = static_cast<DWORD>(-1);
        uc.dwExtraInfoLength = static_cast<DWORD>(-1);
        if (!WinHttpCrackUrl(wurl.c_str(), 0, 0, &uc) || !uc.lpszHostName) {
            err = "the web address is not valid";
            return false;
        }
        const std::wstring host(uc.lpszHostName, uc.dwHostNameLength);
        std::wstring path(uc.lpszUrlPath ? uc.lpszUrlPath : L"/", uc.lpszUrlPath ? uc.dwUrlPathLength : 1);
        if (uc.lpszExtraInfo && uc.dwExtraInfoLength > 0) path.append(uc.lpszExtraInfo, uc.dwExtraInfoLength);
        const bool secure = uc.nScheme == INTERNET_SCHEME_HTTPS;

        Handle session(WinHttpOpen(agent_.c_str(), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME,
                                   WINHTTP_NO_PROXY_BYPASS, 0));
        if (!session.h) {  // before Windows 8.1 there is no automatic proxy mode
            session.h = WinHttpOpen(agent_.c_str(), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME,
                                    WINHTTP_NO_PROXY_BYPASS, 0);
        }
        if (!session.h) {
            err = describe_error(GetLastError());
            return false;
        }
        WinHttpSetTimeouts(session.h, 10000, 10000, 30000, 30000);
        DWORD protocols = 0x0800 | 0x2000;  // TLS 1.2 | TLS 1.3 (the SDK constant for 1.3 is missing in older SDKs)
        if (!WinHttpSetOption(session.h, WINHTTP_OPTION_SECURE_PROTOCOLS, &protocols, sizeof(protocols))) {
            protocols = 0x0800;  // TLS 1.2 only, where 1.3 is unknown
            WinHttpSetOption(session.h, WINHTTP_OPTION_SECURE_PROTOCOLS, &protocols, sizeof(protocols));
        }

        Handle conn(WinHttpConnect(session.h, host.c_str(), uc.nPort, 0));
        if (!conn.h) {
            err = describe_error(GetLastError());
            return false;
        }
        Handle req(WinHttpOpenRequest(conn.h, L"GET", path.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                      secure ? WINHTTP_FLAG_SECURE : 0));
        if (!req.h) {
            err = describe_error(GetLastError());
            return false;
        }
        DWORD policy = WINHTTP_OPTION_REDIRECT_POLICY_DISALLOW_HTTPS_TO_HTTP;
        WinHttpSetOption(req.h, WINHTTP_OPTION_REDIRECT_POLICY, &policy, sizeof(policy));
        const bool is_api = host == L"api.github.com";
        const wchar_t* accept = is_api ? L"Accept: application/vnd.github+json" : L"Accept: application/octet-stream, */*";
        WinHttpAddRequestHeaders(req.h, accept, static_cast<DWORD>(-1), WINHTTP_ADDREQ_FLAG_ADD);

        if (!WinHttpSendRequest(req.h, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
            !WinHttpReceiveResponse(req.h, nullptr)) {
            err = describe_error(GetLastError());
            return false;
        }
        DWORD status = 0, size = sizeof(status);
        WinHttpQueryHeaders(req.h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status,
                            &size, WINHTTP_NO_HEADER_INDEX);
        if (status != 200) {
            if (is_api && (status == 403 || status == 429)) {
                err = "GitHub is limiting requests from your network right now; try again in an hour";
            } else if (status == 404) {
                err = "HTTP 404 (not found)";
            } else {
                err = "HTTP " + std::to_string(status);
            }
            return false;
        }
        DWORD total32 = 0;
        size = sizeof(total32);
        uint64_t total = 0;
        if (WinHttpQueryHeaders(req.h, WINHTTP_QUERY_CONTENT_LENGTH | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                                &total32, &size, WINHTTP_NO_HEADER_INDEX)) {
            total = total32;
        }
        if (total > kMaxDownload) {
            err = "the download is far bigger than expected";
            return false;
        }

        std::vector<uint8_t> chunk(64 * 1024);
        for (;;) {
            DWORD avail = 0;
            if (!WinHttpQueryDataAvailable(req.h, &avail)) {
                err = describe_error(GetLastError());
                return false;
            }
            if (avail == 0) break;
            DWORD want = avail < chunk.size() ? avail : static_cast<DWORD>(chunk.size());
            DWORD got = 0;
            if (!WinHttpReadData(req.h, chunk.data(), want, &got)) {
                err = describe_error(GetLastError());
                return false;
            }
            if (got == 0) break;
            body.insert(body.end(), chunk.begin(), chunk.begin() + got);
            if (body.size() > kMaxDownload) {
                err = "the download is far bigger than expected";
                return false;
            }
            if (progress) progress(body.size(), total);
        }
        if (total != 0 && body.size() != total) {
            err = "the download was cut off";
            return false;
        }
        return true;
    }

private:
    std::wstring agent_;
};

}  // namespace

std::unique_ptr<HttpClient> make_winhttp_client(const std::string& user_agent) {
    return std::unique_ptr<HttpClient>(new WinHttpClient(user_agent));
}

}  // namespace re7mp
