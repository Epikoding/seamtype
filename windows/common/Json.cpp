#include "Json.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace araso {

namespace {

const Json &nullJson() {
    static const Json value;
    return value;
}

const std::string &emptyString() {
    static const std::string value;
    return value;
}

class Parser {
public:
    explicit Parser(const std::string &text) : s_(text) {}

    bool parse(Json &out) {
        skip();
        if (!value(out, 0)) return false;
        skip();
        return i_ == s_.size();
    }

private:
    const std::string &s_;
    size_t i_ = 0;

    void skip() {
        while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\t' || s_[i_] == '\n' || s_[i_] == '\r')) i_++;
    }

    bool literal(const char *word) {
        size_t n = 0;
        while (word[n]) n++;
        if (s_.compare(i_, n, word) != 0) return false;
        i_ += n;
        return true;
    }

    static void appendUtf8(std::string &out, unsigned code) {
        if (code < 0x80) {
            out += static_cast<char>(code);
        } else if (code < 0x800) {
            out += static_cast<char>(0xC0 | (code >> 6));
            out += static_cast<char>(0x80 | (code & 0x3F));
        } else if (code < 0x10000) {
            out += static_cast<char>(0xE0 | (code >> 12));
            out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (code & 0x3F));
        } else {
            out += static_cast<char>(0xF0 | (code >> 18));
            out += static_cast<char>(0x80 | ((code >> 12) & 0x3F));
            out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (code & 0x3F));
        }
    }

    bool hex4(unsigned &code) {
        if (i_ + 4 > s_.size()) return false;
        code = 0;
        for (int k = 0; k < 4; k++) {
            char c = s_[i_++];
            code <<= 4;
            if (c >= '0' && c <= '9') code |= c - '0';
            else if (c >= 'a' && c <= 'f') code |= c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') code |= c - 'A' + 10;
            else return false;
        }
        return true;
    }

    bool string(std::string &out) {
        if (i_ >= s_.size() || s_[i_] != '"') return false;
        i_++;
        while (i_ < s_.size()) {
            char c = s_[i_++];
            if (c == '"') return true;
            if (c != '\\') { out += c; continue; }
            if (i_ >= s_.size()) return false;
            char e = s_[i_++];
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
                unsigned code;
                if (!hex4(code)) return false;
                if (code >= 0xD800 && code < 0xDC00 && i_ + 1 < s_.size() && s_[i_] == '\\' && s_[i_ + 1] == 'u') {
                    i_ += 2;
                    unsigned low;
                    if (!hex4(low)) return false;
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                }
                appendUtf8(out, code);
                break;
            }
            default: return false;
            }
        }
        return false;
    }

    bool value(Json &out, int depth) {
        if (depth > 64 || i_ >= s_.size()) return false;
        char c = s_[i_];
        if (c == '{') {
            i_++;
            out = Json::object();
            skip();
            if (i_ < s_.size() && s_[i_] == '}') { i_++; return true; }
            while (true) {
                skip();
                std::string key;
                if (!string(key)) return false;
                skip();
                if (i_ >= s_.size() || s_[i_] != ':') return false;
                i_++;
                skip();
                Json item;
                if (!value(item, depth + 1)) return false;
                out.set(key, std::move(item));
                skip();
                if (i_ < s_.size() && s_[i_] == ',') { i_++; continue; }
                if (i_ < s_.size() && s_[i_] == '}') { i_++; return true; }
                return false;
            }
        }
        if (c == '[') {
            i_++;
            out = Json::array();
            skip();
            if (i_ < s_.size() && s_[i_] == ']') { i_++; return true; }
            while (true) {
                skip();
                Json item;
                if (!value(item, depth + 1)) return false;
                out.push(std::move(item));
                skip();
                if (i_ < s_.size() && s_[i_] == ',') { i_++; continue; }
                if (i_ < s_.size() && s_[i_] == ']') { i_++; return true; }
                return false;
            }
        }
        if (c == '"') {
            std::string text;
            if (!string(text)) return false;
            out = Json(std::move(text));
            return true;
        }
        if (literal("true")) { out = Json(true); return true; }
        if (literal("false")) { out = Json(false); return true; }
        if (literal("null")) { out = Json(); return true; }
        const char *start = s_.c_str() + i_;
        char *end = nullptr;
        double number = std::strtod(start, &end);
        if (end == start) return false;
        i_ += static_cast<size_t>(end - start);
        out = Json(number);
        return true;
    }
};

}  // namespace

Json Json::parse(const std::string &text, bool *ok) {
    Json out;
    Parser parser(text);
    bool good = parser.parse(out);
    if (ok) *ok = good;
    return good ? out : Json();
}

const std::string &Json::asString() const { return type_ == Type::String ? string_ : emptyString(); }

const Json &Json::operator[](size_t index) const {
    return type_ == Type::Array && index < items_.size() ? items_[index] : nullJson();
}

Json &Json::push(Json value) {
    if (type_ != Type::Array) { *this = array(); }
    items_.push_back(std::move(value));
    return items_.back();
}

bool Json::has(const std::string &key) const {
    for (const auto &member : members_) if (member.first == key) return true;
    return false;
}

const Json &Json::operator[](const std::string &key) const {
    if (type_ != Type::Object) return nullJson();
    for (const auto &member : members_) if (member.first == key) return member.second;
    return nullJson();
}

Json &Json::set(const std::string &key, Json value) {
    if (type_ != Type::Object) { *this = object(); }
    for (auto &member : members_) {
        if (member.first == key) { member.second = std::move(value); return member.second; }
    }
    members_.emplace_back(key, std::move(value));
    return members_.back().second;
}

void Json::remove(const std::string &key) {
    for (auto it = members_.begin(); it != members_.end(); ++it) {
        if (it->first == key) { members_.erase(it); return; }
    }
}

std::string Json::dump() const {
    std::string out;
    write(out);
    return out;
}

void Json::write(std::string &out) const {
    switch (type_) {
    case Type::Null: out += "null"; break;
    case Type::Bool: out += bool_ ? "true" : "false"; break;
    case Type::Number: {
        char buffer[64];
        if (std::isfinite(number_) && number_ == std::floor(number_) && std::fabs(number_) < 1e15) {
            std::snprintf(buffer, sizeof buffer, "%lld", static_cast<long long>(number_));
        } else if (std::isfinite(number_)) {
            std::snprintf(buffer, sizeof buffer, "%.17g", number_);
        } else {
            std::snprintf(buffer, sizeof buffer, "0");
        }
        out += buffer;
        break;
    }
    case Type::String: {
        out += '"';
        for (unsigned char c : string_) {
            switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buffer[8];
                    std::snprintf(buffer, sizeof buffer, "\\u%04x", c);
                    out += buffer;
                } else {
                    out += static_cast<char>(c);
                }
            }
        }
        out += '"';
        break;
    }
    case Type::Array: {
        out += '[';
        for (size_t k = 0; k < items_.size(); k++) {
            if (k) out += ',';
            items_[k].write(out);
        }
        out += ']';
        break;
    }
    case Type::Object: {
        out += '{';
        bool first = true;
        for (const auto &member : members_) {
            if (!first) out += ',';
            first = false;
            Json(member.first).write(out);
            out += ':';
            member.second.write(out);
        }
        out += '}';
        break;
    }
    }
}

}  // namespace araso
