#pragma once
// A tiny, strict JSON reader, only used to read the message files written by the Lua script.
// (Everything else in the bridge reads single numbers with a regex; message lists need real parsing.)
#include <cstdint>
#include <cstdlib>
#include <string>
#include <utility>
#include <vector>

namespace re7mp {
namespace mini {

struct Value {
    enum class Type { Null, Bool, Num, Str, Arr, Obj } type = Type::Null;
    bool b = false;
    double num = 0;
    std::string str;
    std::vector<Value> arr;
    std::vector<std::pair<std::string, Value>> obj;

    const Value* get(const std::string& key) const {
        for (const auto& kv : obj) {
            if (kv.first == key) return &kv.second;
        }
        return nullptr;
    }
};

namespace detail {

struct Parser {
    const std::string& s;
    size_t i = 0;
    explicit Parser(const std::string& text) : s(text) {}

    void ws() {
        while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) ++i;
    }

    static void put_utf8(std::string& out, uint32_t cp) {
        if (cp < 0x80) {
            out += static_cast<char>(cp);
        } else if (cp < 0x800) {
            out += static_cast<char>(0xC0 | (cp >> 6));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            out += static_cast<char>(0xE0 | (cp >> 12));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        } else {
            out += static_cast<char>(0xF0 | (cp >> 18));
            out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        }
    }

    bool hex4(uint32_t& out) {
        if (i + 4 > s.size()) return false;
        out = 0;
        for (int k = 0; k < 4; ++k) {
            const char c = s[i++];
            out <<= 4;
            if (c >= '0' && c <= '9') out |= static_cast<uint32_t>(c - '0');
            else if (c >= 'a' && c <= 'f') out |= static_cast<uint32_t>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') out |= static_cast<uint32_t>(c - 'A' + 10);
            else return false;
        }
        return true;
    }

    bool string(std::string& out) {
        if (i >= s.size() || s[i] != '"') return false;
        ++i;
        out.clear();
        while (i < s.size()) {
            const char c = s[i++];
            if (c == '"') return true;
            if (static_cast<unsigned char>(c) < 0x20) return false;
            if (c != '\\') {
                out += c;
                continue;
            }
            if (i >= s.size()) return false;
            const char e = s[i++];
            switch (e) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    uint32_t cp;
                    if (!hex4(cp)) return false;
                    if (cp >= 0xD800 && cp <= 0xDBFF) {  // surrogate pair
                        uint32_t lo;
                        if (i + 2 > s.size() || s[i] != '\\' || s[i + 1] != 'u') return false;
                        i += 2;
                        if (!hex4(lo) || lo < 0xDC00 || lo > 0xDFFF) return false;
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    }
                    put_utf8(out, cp);
                    break;
                }
                default: return false;
            }
        }
        return false;  // unterminated
    }

    bool value(Value& v, int depth) {
        if (depth > 16) return false;
        ws();
        if (i >= s.size()) return false;
        const char c = s[i];
        if (c == '{') {
            ++i;
            v.type = Value::Type::Obj;
            ws();
            if (i < s.size() && s[i] == '}') {
                ++i;
                return true;
            }
            for (;;) {
                ws();
                std::string key;
                if (!string(key)) return false;
                ws();
                if (i >= s.size() || s[i] != ':') return false;
                ++i;
                Value child;
                if (!value(child, depth + 1)) return false;
                v.obj.emplace_back(std::move(key), std::move(child));
                ws();
                if (i >= s.size()) return false;
                if (s[i] == ',') {
                    ++i;
                    continue;
                }
                if (s[i] == '}') {
                    ++i;
                    return true;
                }
                return false;
            }
        }
        if (c == '[') {
            ++i;
            v.type = Value::Type::Arr;
            ws();
            if (i < s.size() && s[i] == ']') {
                ++i;
                return true;
            }
            for (;;) {
                Value child;
                if (!value(child, depth + 1)) return false;
                v.arr.push_back(std::move(child));
                ws();
                if (i >= s.size()) return false;
                if (s[i] == ',') {
                    ++i;
                    continue;
                }
                if (s[i] == ']') {
                    ++i;
                    return true;
                }
                return false;
            }
        }
        if (c == '"') {
            v.type = Value::Type::Str;
            return string(v.str);
        }
        if (s.compare(i, 4, "true") == 0) {
            i += 4;
            v.type = Value::Type::Bool;
            v.b = true;
            return true;
        }
        if (s.compare(i, 5, "false") == 0) {
            i += 5;
            v.type = Value::Type::Bool;
            return true;
        }
        if (s.compare(i, 4, "null") == 0) {
            i += 4;
            v.type = Value::Type::Null;
            return true;
        }
        // number
        const size_t start = i;
        if (i < s.size() && (s[i] == '-' || s[i] == '+')) ++i;
        while (i < s.size() && ((s[i] >= '0' && s[i] <= '9') || s[i] == '.' || s[i] == 'e' || s[i] == 'E' ||
                                s[i] == '-' || s[i] == '+')) {
            ++i;
        }
        if (i == start) return false;
        char* end = nullptr;
        const std::string tok = s.substr(start, i - start);
        v.num = std::strtod(tok.c_str(), &end);
        if (end != tok.c_str() + tok.size()) return false;
        v.type = Value::Type::Num;
        return true;
    }
};

}  // namespace detail

// Parses a whole document. Returns false on any syntax error or trailing garbage (e.g. a half-written file).
inline bool parse(const std::string& text, Value& out) {
    detail::Parser p(text);
    out = Value{};
    if (!p.value(out, 0)) return false;
    p.ws();
    return p.i == text.size();
}

}  // namespace mini
}  // namespace re7mp
