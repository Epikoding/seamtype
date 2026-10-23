// A small JSON value for the pipe protocol and the settings window: objects keep their key
// order, numbers are doubles, strings are UTF-8.
#pragma once

#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace araso {

class Json {
public:
    enum class Type { Null, Bool, Number, String, Array, Object };

    Json() = default;
    Json(std::nullptr_t) {}
    Json(bool value) : type_(Type::Bool), bool_(value) {}
    Json(int value) : type_(Type::Number), number_(value) {}
    Json(long value) : type_(Type::Number), number_(static_cast<double>(value)) {}
    Json(long long value) : type_(Type::Number), number_(static_cast<double>(value)) {}
    Json(unsigned value) : type_(Type::Number), number_(value) {}
    Json(double value) : type_(Type::Number), number_(value) {}
    Json(const char *value) : type_(Type::String), string_(value) {}
    Json(std::string value) : type_(Type::String), string_(std::move(value)) {}

    static Json array() { Json j; j.type_ = Type::Array; return j; }
    static Json object() { Json j; j.type_ = Type::Object; return j; }

    /// Parses `text`; a Null value (and `ok` false) when it isn't JSON.
    static Json parse(const std::string &text, bool *ok = nullptr);
    std::string dump() const;

    Type type() const { return type_; }
    bool isNull() const { return type_ == Type::Null; }
    bool isObject() const { return type_ == Type::Object; }
    bool isArray() const { return type_ == Type::Array; }
    bool isString() const { return type_ == Type::String; }
    bool isNumber() const { return type_ == Type::Number; }
    bool isBool() const { return type_ == Type::Bool; }

    bool asBool(bool fallback = false) const { return type_ == Type::Bool ? bool_ : fallback; }
    double asNumber(double fallback = 0) const { return type_ == Type::Number ? number_ : fallback; }
    int asInt(int fallback = 0) const { return type_ == Type::Number ? static_cast<int>(number_) : fallback; }
    const std::string &asString() const;

    // Arrays
    size_t size() const { return type_ == Type::Array ? items_.size() : type_ == Type::Object ? members_.size() : 0; }
    const Json &operator[](size_t index) const;
    const Json &operator[](int index) const { return (*this)[static_cast<size_t>(index < 0 ? 0 : index)]; }
    Json &push(Json value);
    const std::vector<Json> &items() const { return items_; }

    // Objects
    bool has(const std::string &key) const;
    const Json &operator[](const std::string &key) const;
    const Json &operator[](const char *key) const { return (*this)[std::string(key)]; }
    Json &set(const std::string &key, Json value);
    void remove(const std::string &key);
    const std::vector<std::pair<std::string, Json>> &members() const { return members_; }

private:
    Type type_ = Type::Null;
    bool bool_ = false;
    double number_ = 0;
    std::string string_;
    std::vector<Json> items_;
    std::vector<std::pair<std::string, Json>> members_;

    void write(std::string &out) const;
};

}  // namespace araso
