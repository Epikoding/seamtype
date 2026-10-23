// The Dictionary and Try Typing panes (DictionaryPane.swift and TypingPane.swift on macOS).
#include "SettingsInternal.h"

#include <windowsx.h>

#include <algorithm>
#include <cwctype>

namespace araso {
namespace settings {

namespace {

std::wstring LanguageName(const std::string &language) {
    if (language == "english") return L("English");
    if (language == "korean") return L("Korean");
    if (language == "mixed") return L("Mixed");
    if (language == "japanese") return L("Japanese");
    return L("My text");
}

std::wstring StatusName(const std::string &status) {
    if (status == "added") return L("Added");
    if (status == "once") return L("Corrected once");
    return L("Remembered");
}

const char *kFilters[] = {"all", "added", "remembered", "once"};

std::wstring Lower(std::wstring text) {
    std::transform(text.begin(), text.end(), text.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
    return text;
}

/// Fills the list with the words the filter and the search let through.
void FillWords() {
    if (!g.wordList) return;
    ListView_DeleteAllItems(g.wordList);
    g.shownWords.clear();
    std::wstring search = Lower(g.search);
    int row = 0;
    for (const Json &word : g.model["words"].items()) {
        std::string status = word["status"].asString();
        if (g.filter > 0 && status != kFilters[g.filter]) continue;
        std::wstring keys = Wide(word["keys"].asString()), text = Wide(word["text"].asString());
        if (!search.empty() && Lower(keys).find(search) == std::wstring::npos && Lower(text).find(search) == std::wstring::npos) continue;
        std::wstring apps;
        for (const Json &app : word["apps"].items()) apps += (apps.empty() ? L"" : L", ") + Wide(app.asString());
        const Json &days = word["daysLeft"];
        Row(g.wordList, row++, {keys, text + L"  ·  " + LanguageName(word["language"].asString()), StatusName(status),
                                apps.empty() ? L("Every app") : apps,
                                days.isNumber() ? L("%ld days", {std::to_wstring(days.asInt())}) : L"—"});
        g.shownWords.push_back(word);
    }
}

const Json *SelectedWord() {
    int row = g.wordList ? Selected(g.wordList) : -1;
    return row >= 0 && row < static_cast<int>(g.shownWords.size()) ? &g.shownWords[row] : nullptr;
}

}  // namespace

// MARK: - Dictionary

void BuildDictionary() {
    int counts[4] = {0, 0, 0, 0};
    for (const Json &word : g.model["words"].items()) {
        counts[0]++;
        std::string status = word["status"].asString();
        for (int k = 1; k < 4; k++) if (status == kFilters[k]) counts[k]++;
    }
    std::vector<std::wstring> filters = {L("All %ld", {std::to_wstring(counts[0])}), L("Added %ld", {std::to_wstring(counts[1])}),
                                         L("Remembered %ld", {std::to_wstring(counts[2])}),
                                         L("Corrected once %ld", {std::to_wstring(counts[3])})};
    int top = g.y;
    HWND filter = Make(WC_COMBOBOXW, L"", CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL, Pad(), g.y, S(180), S(200), g.font,
                       [](HWND control, int code) {
                           if (code != CBN_SELCHANGE) return;
                           g.filter = std::max(0, ComboBox_GetCurSel(control));
                           Rebuild();
                       });
    for (const auto &item : filters) ComboBox_AddString(filter, item.c_str());
    ComboBox_SetCurSel(filter, g.filter);
    HWND search = Make(WC_EDITW, g.search, WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL, Pad() + S(190), g.y, S(220), S(26), g.font,
                       [](HWND control, int code) {
                           if (code != EN_CHANGE) return;
                           wchar_t text[256] = L"";
                           GetWindowTextW(control, text, 256);
                           g.search = text;
                           FillWords();
                       });
    Edit_SetCueBannerText(search, L("Search").c_str());
    Push(L("Add…"), Pad() + ContentWidth() - S(110), S(110), [] { EditWord(nullptr, ""); });
    g.y = top + S(36);
    const char *notes[] = {"These keys come out as written here, also with a particle after them.",
                           "Words you added here. They always come out this way.",
                           "Words you switched the same way twice. They always come out this way.",
                           "Words you switched once. They only lean that way, and are forgotten after 30 days unless you switch or type them again."};
    Note(L(notes[g.filter]));

    g.wordList = List({{L("Keys"), 120}, {L("Result"), 170}, {L("Status"), 100}, {L("Apps"), 110}, {L("Expires"), 70}}, S(230));
    FillWords();
    g.notifies[GetDlgCtrlID(g.wordList)] = [](NMHDR *header) {
        if (header->code == NM_DBLCLK) {
            if (const Json *word = SelectedWord()) EditWord(word, "");
        }
    };
    if (g.shownWords.empty()) {
        Note(g.model["words"].size() == 0 ? L("No words yet") : L("No matches"));
        if (g.model["words"].size() == 0) {
            Note(L("Add a word with +, or switch a word that came out wrong with the language switch key: corrected the same way twice, it's remembered here."));
        }
    }
    int x = Pad();
    Push(L("Edit…"), x, S(110), [] { if (const Json *word = SelectedWord()) EditWord(word, ""); });
    Push(L("Keep for Good"), x + S(120), S(140), [] {
        const Json *word = SelectedWord();
        if (!word || (*word)["status"].asString() == "added") return;
        Json change = Json::object();
        change.set("keepWord", (*word)["id"]);
        Apply(change);
    });
    Push(L("Remove"), x + S(270), S(100), [] {
        const Json *word = SelectedWord();
        if (!word) return;
        Json change = Json::object();
        change.set("removeWord", (*word)["id"]);
        Apply(change);
    });
    Push(L("Forget Learned Words…"), x + ContentWidth() - S(220), S(220), [] {
        if (!Confirm(L("Forget every learned word?"), L("Words you added stay. This can't be undone."))) return;
        Json change = Json::object();
        change.set("forgetLearned", true);
        Apply(change);
    });
    g.y += S(38);
}

/// Adds a word (`word` nil) or changes one: the keys as typed, the reading they come out as, and
/// the app they're for.
void EditWord(const Json *word, const std::string &keys) {
    Json original = word ? *word : Json();
    Dialog dialog(word ? L("Change Word") : L("Add to Dictionary"), 460, 380);
    dialog.Add(L"STATIC", L("Type the keys"), SS_NOPREFIX, 20, 14, 420, 20, nullptr, g.bold);
    HWND field = dialog.Add(WC_EDITW, Wide(word ? original["keys"].asString() : keys), WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL,
                            20, 36, 420, 28);
    // The keys go in as typed, not through an input method (Araso's own included).
    WithoutInputMethod(field);
    dialog.Add(L"STATIC", L("Type the keys as you would on the English layout. They go in as typed, not through an input method."),
               SS_NOPREFIX, 20, 68, 420, 36, nullptr, g.fine);
    dialog.Add(L"STATIC", L("Comes out as"), SS_NOPREFIX, 20, 108, 420, 20, nullptr, g.bold);
    // Up to four readings, refilled as the keys change.
    HWND choices[4];
    std::vector<std::string> languages(4);
    std::string chosen = word ? original["language"].asString() : "english";
    for (int k = 0; k < 4; k++) {
        choices[k] = dialog.Add(L"BUTTON", L"", BS_AUTORADIOBUTTON | WS_TABSTOP | (k == 0 ? WS_GROUP : 0), 32, 132 + 26 * k, 400, 24,
                                [&languages, &chosen, k](HWND, int code) {
                                    if (code == BN_CLICKED) chosen = languages[k];
                                });
    }
    auto refill = [&]() {
        wchar_t text[128] = L"";
        GetWindowTextW(field, text, 128);
        Json request = Json::object();
        request.set("op", "readings");
        request.set("keys", Utf8(text));
        Json answer = Request(request);
        const Json &list = answer["choices"];
        bool found = false;
        for (int k = 0; k < 4; k++) {
            bool shown = k < static_cast<int>(list.size());
            languages[k] = shown ? list[k]["language"].asString() : "";
            std::wstring label = shown ? LanguageName(languages[k]) + L"    " + Wide(list[k]["text"].asString()) : L"";
            SetWindowTextW(choices[k], label.c_str());
            ShowWindow(choices[k], shown ? SW_SHOW : SW_HIDE);
            Button_SetCheck(choices[k], shown && languages[k] == chosen ? BST_CHECKED : BST_UNCHECKED);
            found = found || (shown && languages[k] == chosen);
        }
        if (!found && list.size() > 0) {
            chosen = languages[0];
            Button_SetCheck(choices[0], BST_CHECKED);
        }
    };
    dialog.Add(L"STATIC", L("App"), SS_NOPREFIX | SS_CENTERIMAGE, 20, 244, 60, 26);
    HWND app = dialog.Add(WC_COMBOBOXW, L"", CBS_DROPDOWN | WS_TABSTOP | WS_VSCROLL, 84, 244, 356, 200);
    ComboBox_AddString(app, L("Every app").c_str());
    for (const Json &item : g.model["apps"].items()) ComboBox_AddString(app, Wide(item["app"].asString()).c_str());
    const Json &apps = original["apps"];
    if (apps.size() > 0) SetWindowTextW(app, Wide(apps[0].asString()).c_str());
    else ComboBox_SetCurSel(app, 0);

    if (word) {
        dialog.Add(L"BUTTON", L("Remove"), BS_PUSHBUTTON | WS_TABSTOP, 20, 330, 100, 30, [&](HWND, int) {
            Json change = Json::object();
            change.set("removeWord", original["id"]);
            Apply(change);
            dialog.Close(false);
        });
    }
    dialog.Add(L"BUTTON", L("Cancel"), BS_PUSHBUTTON | WS_TABSTOP, 236, 330, 96, 30, [&dialog](HWND, int) { dialog.Close(false); });
    dialog.Add(L"BUTTON", word ? L("Save") : L("Add"), BS_DEFPUSHBUTTON | WS_TABSTOP, 344, 330, 96, 30,
               [&dialog](HWND, int) { dialog.Close(true); });
    // The field reports its changes to the dialog.
    SetWindowSubclass(field, [](HWND window, UINT message, WPARAM wParam, LPARAM lParam, UINT_PTR, DWORD_PTR data) -> LRESULT {
        LRESULT result = DefSubclassProc(window, message, wParam, lParam);
        if (message == WM_CHAR || message == WM_KEYUP || message == WM_PASTE || message == WM_CUT) {
            (*reinterpret_cast<std::function<void()> *>(data))();
        }
        return result;
    }, 1, reinterpret_cast<DWORD_PTR>(&refill));
    refill();
    bool accepted = dialog.Run();
    RemoveWindowSubclass(field, nullptr, 1);
    if (!accepted) return;

    wchar_t text[128] = L"";
    GetWindowTextW(field, text, 128);
    std::string typed = Utf8(text);
    if (typed.empty()) return;
    wchar_t appText[260] = L"";
    GetWindowTextW(app, appText, 260);
    Json entry = Json::object();
    entry.set("keys", typed);
    entry.set("as", chosen.empty() ? "english" : chosen);
    entry.set("from", "user");
    std::wstring appName = appText;
    if (!appName.empty() && appName != L("Every app")) {
        Json list = Json::array();
        list.push(Utf8(appName));
        entry.set("apps", list);
    }
    Json change = Json::object();
    change.set("addWord", entry);
    if (word) change.set("replacing", original["id"]);
    Apply(change);
}

// MARK: - Try Typing

namespace {

void FillTraces() {
    if (!g.traceList) return;
    ListView_DeleteAllItems(g.traceList);
    int row = 0;
    for (auto it = g.traces.rbegin(); it != g.traces.rend(); ++it) {
        const Json &trace = *it;
        wchar_t confidence[16];
        swprintf(confidence, 16, L"%.2f", trace["confidence"].asNumber());
        Row(g.traceList, row++, {Wide(trace["keys"].asString()), Wide(trace["output"].asString()),
                                 LanguageName(trace["language"].asString()), confidence,
                                 Wide(trace["explanation"].asString())});
    }
}

}  // namespace

void AddTrace(const Json &trace) {
    if (!trace.isObject()) return;
    // A word still being typed replaces the one before it until the word is done.
    if (!g.traces.empty() && g.traces.back()["partial"].asBool()) g.traces.pop_back();
    g.traces.push_back(trace);
    if (g.traces.size() > 50) g.traces.erase(g.traces.begin());
    FillTraces();
}

void BuildTyping() {
    Note(L("Type here on the English layout, e.g. dkssud hello"));
    HWND field = Make(WC_EDITW, L"", WS_BORDER | WS_TABSTOP | ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL | ES_WANTRETURN,
                      Pad(), g.y, ContentWidth(), S(110), g.font);
    g.y += S(118);
    Note(L("The language switch key changes the word's reading, also right after the word."));
    Push(L("Clear"), Pad(), S(100), [field] {
        SetWindowTextW(field, L"");
        g.traces.clear();
        FillTraces();
        SetFocus(field);
    });
    Push(L("Add to Dictionary…"), Pad() + S(110), S(180), [] {
        int row = g.traceList ? Selected(g.traceList) : -1;
        if (row < 0 || row >= static_cast<int>(g.traces.size())) return;
        EditWord(nullptr, g.traces[g.traces.size() - 1 - static_cast<size_t>(row)]["keys"].asString());
    });
    g.y += S(38);
    Heading(L("How it was decided"));
    g.traceList = List({{L("Keys"), 110}, {L("Result"), 120}, {L("Language"), 80}, {L("Confidence"), 80}, {L("Why"), 260}}, S(190));
    FillTraces();
    if (g.traces.empty()) Note(L("Type a word above to see its scores."));
    SetFocus(field);
}

}  // namespace settings
}  // namespace araso
