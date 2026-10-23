#include "TextService.h"

#include "DisplayAttributes.h"
#include "LangBarButton.h"

#include <algorithm>
#include <cstring>
#include <new>

namespace araso {

namespace {

/// How far back the field is read: InputSession reads up to 256 UTF-16 units before the word.
constexpr LONG kLookBehind = 256;

UINT PendingMessage() {
    static UINT message = RegisterWindowMessageW(kPendingMessage);
    return message;
}

bool IsModifier(WPARAM vk) {
    switch (vk) {
    case VK_SHIFT: case VK_LSHIFT: case VK_RSHIFT:
    case VK_CONTROL: case VK_LCONTROL: case VK_RCONTROL:
    case VK_MENU: case VK_LMENU: case VK_RMENU:
    case VK_LWIN: case VK_RWIN:
        return true;
    default:
        return false;
    }
}

/// Screen pixels, whatever the app's DPI awareness: an app that isn't DPI aware reports its text in
/// scaled coordinates, and the host (per-monitor aware) places its windows in physical ones.
RECT Physical(HWND window, RECT rect) {
    if (!window) return rect;
    POINT topLeft = {rect.left, rect.top}, bottomRight = {rect.right, rect.bottom};
    if (LogicalToPhysicalPointForPerMonitorDPI(window, &topLeft) &&
        LogicalToPhysicalPointForPerMonitorDPI(window, &bottomRight)) {
        rect = {topLeft.x, topLeft.y, bottomRight.x, bottomRight.y};
    }
    return rect;
}

Json RectJson(const RECT &rect) {
    Json out = Json::array();
    out.push(static_cast<int>(rect.left));
    out.push(static_cast<int>(rect.top));
    out.push(static_cast<int>(rect.right));
    out.push(static_cast<int>(rect.bottom));
    return out;
}

template <typename T> void SafeRelease(T *&pointer) {
    if (pointer) {
        pointer->Release();
        pointer = nullptr;
    }
}

}  // namespace

// MARK: - EditSession

STDMETHODIMP EditSession::QueryInterface(REFIID riid, void **object) {
    if (!object) return E_INVALIDARG;
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfEditSession)) {
        *object = static_cast<ITfEditSession *>(this);
        AddRef();
        return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
}

// MARK: - TextService

TextService::TextService() { DllAddRef(); }
TextService::~TextService() { DllRelease(); }

STDMETHODIMP TextService::QueryInterface(REFIID riid, void **object) {
    if (!object) return E_INVALIDARG;
    *object = nullptr;
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfTextInputProcessor)) {
        *object = static_cast<ITfTextInputProcessor *>(this);
    } else if (IsEqualIID(riid, kIID_ITfTextInputProcessorEx)) {
        *object = static_cast<ITfTextInputProcessorEx *>(this);
    } else if (IsEqualIID(riid, IID_ITfThreadMgrEventSink)) {
        *object = static_cast<ITfThreadMgrEventSink *>(this);
    } else if (IsEqualIID(riid, IID_ITfKeyEventSink)) {
        *object = static_cast<ITfKeyEventSink *>(this);
    } else if (IsEqualIID(riid, IID_ITfCompositionSink)) {
        *object = static_cast<ITfCompositionSink *>(this);
    } else if (IsEqualIID(riid, kIID_ITfDisplayAttributeProvider)) {
        *object = static_cast<ITfDisplayAttributeProvider *>(this);
    }
    if (!*object) return E_NOINTERFACE;
    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) TextService::AddRef() { return InterlockedIncrement(&references_); }

STDMETHODIMP_(ULONG) TextService::Release() {
    LONG count = InterlockedDecrement(&references_);
    if (!count) delete this;
    return count;
}

STDMETHODIMP TextService::Activate(ITfThreadMgr *threadMgr, TfClientId clientId) {
    return ActivateEx(threadMgr, clientId, 0);
}

STDMETHODIMP TextService::ActivateEx(ITfThreadMgr *threadMgr, TfClientId clientId, DWORD) {
    threadMgr_ = threadMgr;
    threadMgr_->AddRef();
    clientId_ = clientId;
    app_ = ProcessName();

    ITfSource *source = nullptr;
    if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfSource, reinterpret_cast<void **>(&source)))) {
        source->AdviseSink(IID_ITfThreadMgrEventSink, static_cast<ITfThreadMgrEventSink *>(this), &threadMgrSinkCookie_);
        source->Release();
    }
    ITfKeystrokeMgr *keystrokes = nullptr;
    if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void **>(&keystrokes)))) {
        keySinkAdvised_ = SUCCEEDED(keystrokes->AdviseKeyEventSink(clientId_, static_cast<ITfKeyEventSink *>(this), TRUE));
        keystrokes->Release();
    }
    RegisterAttributes();
    CreateMessageWindow();

    button_ = new (std::nothrow) LangBarButton(this);
    if (button_) {
        ITfLangBarItemMgr *items = nullptr;
        if (SUCCEEDED(threadMgr_->QueryInterface(kIID_ITfLangBarItemMgr, reinterpret_cast<void **>(&items)))) {
            items->AddItem(button_);
            items->Release();
        }
    }
    // The keyboard is "open": Araso has no off mode of its own (pause is per text field).
    ITfCompartmentMgr *compartments = nullptr;
    if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfCompartmentMgr, reinterpret_cast<void **>(&compartments)))) {
        ITfCompartment *open = nullptr;
        if (SUCCEEDED(compartments->GetCompartment(kGuidCompartmentKeyboardOpenClose, &open))) {
            VARIANT value;
            VariantInit(&value);
            value.vt = VT_I4;
            value.lVal = TRUE;
            open->SetValue(clientId_, &value);
            open->Release();
        }
        compartments->Release();
    }
    host_.Attach(app_, window_);
    Log("activated in %s", Utf8(app_).c_str());
    return S_OK;
}

STDMETHODIMP TextService::Deactivate() {
    if (composition_ && compositionContext_) CommitIn(compositionContext_, "blur");
    host_.Detach();
    if (button_) {
        ITfLangBarItemMgr *items = nullptr;
        if (threadMgr_ && SUCCEEDED(threadMgr_->QueryInterface(kIID_ITfLangBarItemMgr, reinterpret_cast<void **>(&items)))) {
            items->RemoveItem(button_);
            items->Release();
        }
        button_->Release();
        button_ = nullptr;
    }
    if (threadMgr_) {
        ITfKeystrokeMgr *keystrokes = nullptr;
        if (keySinkAdvised_ && SUCCEEDED(threadMgr_->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void **>(&keystrokes)))) {
            keystrokes->UnadviseKeyEventSink(clientId_);
            keystrokes->Release();
        }
        keySinkAdvised_ = false;
        ITfSource *source = nullptr;
        if (threadMgrSinkCookie_ != TF_INVALID_COOKIE &&
            SUCCEEDED(threadMgr_->QueryInterface(IID_ITfSource, reinterpret_cast<void **>(&source)))) {
            source->UnadviseSink(threadMgrSinkCookie_);
            source->Release();
        }
        threadMgrSinkCookie_ = TF_INVALID_COOKIE;
    }
    SafeRelease(composition_);
    SafeRelease(compositionContext_);
    DestroyMessageWindow();
    SafeRelease(threadMgr_);
    clientId_ = TF_CLIENTID_NULL;
    return S_OK;
}

// MARK: Focus

STDMETHODIMP TextService::OnSetFocus(ITfDocumentMgr *focus, ITfDocumentMgr *) {
    // What was being typed in the last field goes in there, as shown.
    if (composition_ && compositionContext_) CommitIn(compositionContext_, "blur");
    if (!focus) return S_OK;
    Json request = Json::object();
    request.set("op", "focus");
    request.set("app", Utf8(app_));
    Json response;
    host_.Request(request, response, 300);
    return S_OK;
}

STDMETHODIMP TextService::OnSetFocus(BOOL) { return S_OK; }

/// Commits what is being typed in `context` (an asynchronous edit session: focus is moving).
void TextService::CommitIn(ITfContext *context, const char *op) {
    std::string name = op;
    context->AddRef();
    HRESULT hr = Edit(context, false, [this, context, name](TfEditCookie cookie) {
        Json request = Json::object();
        request.set("op", name);
        bool masked = false;
        request.set("context", Snapshot(cookie, context, masked));
        bool handled = false;
        if (!Exchange(cookie, context, request, handled)) EndComposition(cookie);
        // Whatever the host did, nothing stays composed in a field that lost the focus.
        if (composition_) EndComposition(cookie);
        context->Release();
        return S_OK;
    });
    if (FAILED(hr)) context->Release();
}

ITfContext *TextService::FocusedContext() {
    if (!threadMgr_) return nullptr;
    ITfDocumentMgr *document = nullptr;
    if (FAILED(threadMgr_->GetFocus(&document)) || !document) return nullptr;
    ITfContext *context = nullptr;
    document->GetTop(&context);
    document->Release();
    return context;
}

// MARK: Keys

/// Whether the key may go to the host. Modifiers go too (their taps switch and pause), and the
/// session decides the rest: a key it doesn't take still reaches the app (`OnKeyDown`).
bool TextService::Takes(WPARAM vk, bool down) const {
    if (!threadMgr_) return false;
    if (vk == VK_CAPITAL || vk == VK_NUMLOCK || vk == VK_SCROLL || vk == VK_PROCESSKEY || vk == VK_PACKET) return false;
    // A key going up matters only for a modifier's tap.
    if (!down) return IsModifier(vk);
    return true;
}

/// A key with Ctrl, Alt or the Windows key (not a modifier itself): an app's shortcut unless the
/// host says the session takes it, so the app's accelerators see it untouched.
bool TextService::IsShortcut(WPARAM vk) const {
    if (IsModifier(vk)) return false;
    return GetKeyState(VK_CONTROL) < 0 || GetKeyState(VK_MENU) < 0 || GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0;
}

/// Asked once per key: OnTestKeyDown may come more than once for one key (a peek, then the real
/// thing) and OnKeyDown follows it; they all get the first answer.
bool TextService::HostTakes(WPARAM wParam, LPARAM lParam) {
    DWORD now = GetTickCount();
    if (asked_.valid && asked_.vk == wParam && asked_.lParam == lParam && now - asked_.at < 1000) return asked_.taken;
    Json request = Json::object();
    request.set("op", "test");
    request.set("key", KeyJson(wParam, lParam));
    Json response;
    bool taken = host_.Request(request, response, 200) && response["reply"]["handled"].asBool();
    asked_ = {true, wParam, lParam, now, taken};
    return taken;
}

STDMETHODIMP TextService::OnTestKeyDown(ITfContext *, WPARAM wParam, LPARAM lParam, BOOL *eaten) {
    *eaten = Takes(wParam, true) && (!IsShortcut(wParam) || HostTakes(wParam, lParam));
    return S_OK;
}

STDMETHODIMP TextService::OnKeyDown(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) {
    *eaten = FALSE;
    if (!Takes(wParam, true)) return S_OK;
    bool shortcut = IsShortcut(wParam);
    bool taken = !shortcut || HostTakes(wParam, lParam);
    asked_.valid = false; // the key is done with: the next press asks again
    if (!taken) return S_OK;
    // A modifier held down repeats: only its first press counts.
    if (IsModifier(wParam) && (lParam & (1 << 30))) return S_OK;
    HandleKey(context, wParam, lParam, "key", eaten);
    return S_OK;
}

STDMETHODIMP TextService::OnTestKeyUp(ITfContext *, WPARAM wParam, LPARAM, BOOL *eaten) {
    *eaten = Takes(wParam, false);
    return S_OK;
}

STDMETHODIMP TextService::OnKeyUp(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) {
    *eaten = FALSE;
    if (!Takes(wParam, false)) return S_OK;
    HandleKey(context, wParam, lParam, "keyUp", eaten);
    return S_OK;
}

Json TextService::KeyJson(WPARAM wParam, LPARAM lParam) const {
    Json key = Json::object();
    key.set("vk", static_cast<int>(wParam));
    key.set("scan", static_cast<int>((lParam >> 16) & 0xFF));
    key.set("extended", ((lParam >> 24) & 1) != 0);
    key.set("shift", GetKeyState(VK_SHIFT) < 0);
    key.set("ctrl", GetKeyState(VK_CONTROL) < 0);
    key.set("alt", GetKeyState(VK_MENU) < 0);
    key.set("win", GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0);
    key.set("capsLock", (GetKeyState(VK_CAPITAL) & 1) != 0);
    return key;
}

void TextService::HandleKey(ITfContext *context, WPARAM wParam, LPARAM lParam, const char *op, BOOL *eaten) {
    Json key = KeyJson(wParam, lParam);
    std::string name = op;
    bool handled = false;
    HRESULT hr = Edit(context, true, [&](TfEditCookie cookie) {
        bool masked = false;
        Json request = Json::object();
        request.set("op", name);
        request.set("key", key);
        request.set("context", Snapshot(cookie, context, masked));
        // A password field: the keys go to the app as typed, as when paused (MaskedField on macOS).
        if (masked) return S_OK;
        Json rects = Rects(cookie, context);
        request.set("rects", rects);
        Exchange(cookie, context, request, handled);
        return S_OK;
    });
    if (FAILED(hr)) Log("no edit session for a key (0x%08lx)", static_cast<unsigned long>(hr));
    *eaten = handled ? TRUE : FALSE;
}

bool TextService::Exchange(TfEditCookie cookie, ITfContext *context, Json request, bool &handled) {
    Json response;
    if (!host_.Request(request, response)) return false;
    const Json &reply = response["reply"];
    handled = reply["handled"].asBool();
    ApplyOps(cookie, context, reply["ops"], reply["converting"].asBool());
    // How Try Typing's word was decided: for the settings window, which is in this process (the host
    // only says so to the text service in its own exe), handed over without waiting on anything.
    const Json &trace = response["ui"]["trace"];
    if (trace.isObject()) {
        HWND settings = FindWindowW(kSettingsWindowClass, nullptr);
        DWORD owner = 0;
        if (settings) GetWindowThreadProcessId(settings, &owner);
        if (owner == GetCurrentProcessId()) {
            std::string text = trace.dump();
            // The process heap: the settings window frees it, from another module.
            char *copy = static_cast<char *>(HeapAlloc(GetProcessHeap(), 0, text.size() + 1));
            if (copy) {
                memcpy(copy, text.c_str(), text.size() + 1);
                if (!PostMessageW(settings, RegisterWindowMessageW(kTraceMessage), 0, reinterpret_cast<LPARAM>(copy))) {
                    HeapFree(GetProcessHeap(), 0, copy);
                }
            }
        }
    }
    // Where the word and the caret are now: the host places its windows there.
    if (response["ui"].isObject()) {
        Json place = Json::object();
        place.set("op", "place");
        place.set("rects", Rects(cookie, context));
        Json ignored;
        host_.Request(place, ignored, 200);
    }
    return true;
}

HRESULT TextService::Edit(ITfContext *context, bool sync, std::function<HRESULT(TfEditCookie)> body) {
    if (!context) return E_INVALIDARG;
    EditSession *session = new (std::nothrow) EditSession(std::move(body));
    if (!session) return E_OUTOFMEMORY;
    HRESULT result = E_FAIL;
    DWORD flags = TF_ES_READWRITE | (sync ? TF_ES_SYNC : TF_ES_ASYNCDONTCARE);
    HRESULT hr = context->RequestEditSession(clientId_, session, flags, &result);
    session->Release();
    return FAILED(hr) ? hr : result;
}

void TextService::FetchPending() {
    ITfContext *context = FocusedContext();
    if (!context) return;
    HRESULT hr = Edit(context, false, [this, context](TfEditCookie cookie) {
        Json request = Json::object();
        request.set("op", "pending");
        bool masked = false;
        request.set("context", Snapshot(cookie, context, masked));
        bool handled = false;
        Exchange(cookie, context, request, handled);
        context->Release();
        return S_OK;
    });
    if (FAILED(hr)) context->Release();
}

// MARK: The field

Json TextService::Snapshot(TfEditCookie cookie, ITfContext *context, bool &masked) {
    masked = false;
    Json out = Json::object();
    Json selectionJson = Json::array();
    selectionJson.push(-1);
    selectionJson.push(0);
    out.set("selection", selectionJson);
    out.set("text", "");
    out.set("start", 0);

    TF_SELECTION selection = {};
    ULONG fetched = 0;
    if (FAILED(context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection, &fetched)) || fetched == 0) return out;
    ITfRange *selected = selection.range;

    // A password field says so through its input scope.
    ITfReadOnlyProperty *scopes = nullptr;
    if (SUCCEEDED(context->GetAppProperty(kGuidPropInputScope, &scopes)) && scopes) {
        VARIANT value;
        VariantInit(&value);
        if (SUCCEEDED(scopes->GetValue(cookie, selected, &value)) && value.vt == VT_UNKNOWN && value.punkVal) {
            ITfInputScope *scope = nullptr;
            if (SUCCEEDED(value.punkVal->QueryInterface(kIID_ITfInputScope, reinterpret_cast<void **>(&scope)))) {
                InputScope *list = nullptr;
                UINT count = 0;
                if (SUCCEEDED(scope->GetInputScopes(&list, &count)) && list) {
                    for (UINT k = 0; k < count; k++) {
                        if (list[k] == IS_PASSWORD) masked = true;
                    }
                    CoTaskMemFree(list);
                }
                scope->Release();
            }
        }
        VariantClear(&value);
        scopes->Release();
    }
    out.set("masked", masked);

    ITfRangeACP *selectedACP = nullptr;
    LONG selStart = 0, selLength = 0;
    if (FAILED(selected->QueryInterface(IID_ITfRangeACP, reinterpret_cast<void **>(&selectedACP))) ||
        FAILED(selectedACP->GetExtent(&selStart, &selLength))) {
        // A field without character positions: the session works without them.
        SafeRelease(selectedACP);
        selected->Release();
        return out;
    }
    selectedACP->Release();
    Json sel = Json::array();
    sel.push(static_cast<int>(selStart));
    sel.push(static_cast<int>(selLength));
    out.set("selection", sel);

    // The composition, and the text from 256 units before it (or the caret) to its end.
    ITfRange *anchor = nullptr;
    LONG compStart = 0, compLength = 0;
    bool composing = false;
    if (composition_ && compositionContext_ == context) {
        ITfRange *range = nullptr;
        if (SUCCEEDED(composition_->GetRange(&range)) && range) {
            ITfRangeACP *acp = nullptr;
            if (SUCCEEDED(range->QueryInterface(IID_ITfRangeACP, reinterpret_cast<void **>(&acp)))) {
                if (SUCCEEDED(acp->GetExtent(&compStart, &compLength)) && compLength > 0) composing = true;
                acp->Release();
            }
            // A copy to move about: the composition's own range must stay where it is.
            if (composing) range->Clone(&anchor);
            range->Release();
        }
    }
    if (composing) {
        Json marked = Json::array();
        marked.push(static_cast<int>(compStart));
        marked.push(static_cast<int>(compLength));
        out.set("marked", marked);
    }
    if (!anchor) selected->Clone(&anchor);
    selected->Release();
    if (!anchor) return out;

    LONG moved = 0;
    anchor->ShiftStart(cookie, -kLookBehind, &moved, nullptr);
    LONG start = (composing ? compStart : selStart) + moved;
    // The selection may run past the composition: read to whichever ends later.
    LONG end = composing ? std::max(compStart + compLength, selStart + selLength) : selStart + selLength;
    LONG want = end - start;
    std::wstring text;
    if (want > 0) {
        ITfRangeACP *acp = nullptr;
        if (SUCCEEDED(anchor->QueryInterface(IID_ITfRangeACP, reinterpret_cast<void **>(&acp)))) {
            acp->SetExtent(start, want);
            acp->Release();
        }
        std::vector<wchar_t> buffer(static_cast<size_t>(want) + 1);
        ULONG got = 0;
        if (SUCCEEDED(anchor->GetText(cookie, 0, buffer.data(), static_cast<ULONG>(want), &got))) {
            text.assign(buffer.data(), got);
        } else {
            out.set("unreadable", true);
        }
    }
    anchor->Release();
    // Text with embedded objects reads shorter than its positions: then the positions don't line up.
    if (static_cast<LONG>(text.size()) != want) out.set("unreadable", true);
    out.set("text", Utf8(text));
    out.set("start", static_cast<int>(start));
    return out;
}

/// The composition's rectangle on screen, and the caret's.
Json TextService::Rects(TfEditCookie cookie, ITfContext *context) {
    Json out = Json::object();
    ITfContextView *view = nullptr;
    if (FAILED(context->GetActiveView(&view)) || !view) return out;
    HWND window = nullptr;
    view->GetWnd(&window);
    if (composition_ && compositionContext_ == context) {
        ITfRange *range = nullptr;
        if (SUCCEEDED(composition_->GetRange(&range)) && range) {
            RECT rect = {};
            BOOL clipped = FALSE;
            if (SUCCEEDED(view->GetTextExt(cookie, range, &rect, &clipped)) && rect.bottom > rect.top) {
                out.set("word", RectJson(Physical(window, rect)));
            }
            range->Release();
        }
    }
    TF_SELECTION selection = {};
    ULONG fetched = 0;
    if (SUCCEEDED(context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection, &fetched)) && fetched) {
        ITfRange *caret = nullptr;
        if (SUCCEEDED(selection.range->Clone(&caret)) && caret) {
            caret->Collapse(cookie, TF_ANCHOR_END);
            RECT rect = {};
            BOOL clipped = FALSE;
            if (SUCCEEDED(view->GetTextExt(cookie, caret, &rect, &clipped)) && rect.bottom > rect.top) {
                out.set("caret", RectJson(Physical(window, rect)));
            }
            caret->Release();
        }
        selection.range->Release();
    }
    view->Release();
    return out;
}

ITfRange *TextService::RangeAt(TfEditCookie cookie, ITfContext *context, LONG start, LONG length) {
    TF_SELECTION selection = {};
    ULONG fetched = 0;
    if (FAILED(context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection, &fetched)) || !fetched) return nullptr;
    ITfRange *range = nullptr;
    selection.range->Clone(&range);
    selection.range->Release();
    if (!range) return nullptr;
    ITfRangeACP *acp = nullptr;
    if (FAILED(range->QueryInterface(IID_ITfRangeACP, reinterpret_cast<void **>(&acp))) ||
        FAILED(acp->SetExtent(start, length))) {
        SafeRelease(acp);
        range->Release();
        return nullptr;
    }
    acp->Release();
    return range;
}

void TextService::MoveCaretToEnd(TfEditCookie cookie, ITfContext *context, ITfRange *range) {
    ITfRange *caret = nullptr;
    if (FAILED(range->Clone(&caret)) || !caret) return;
    caret->Collapse(cookie, TF_ANCHOR_END);
    TF_SELECTION selection = {};
    selection.range = caret;
    selection.style.ase = TF_AE_NONE;
    selection.style.fInterimChar = FALSE;
    context->SetSelection(cookie, 1, &selection);
    caret->Release();
}

void TextService::EndComposition(TfEditCookie cookie) {
    if (!composition_) return;
    ITfRange *range = nullptr;
    if (compositionContext_ && SUCCEEDED(composition_->GetRange(&range)) && range) {
        ClearAttributes(cookie, compositionContext_, range);
        range->Release();
    }
    composition_->EndComposition(cookie);
    SafeRelease(composition_);
    SafeRelease(compositionContext_);
}

/// The edits, in order: each replaces its range (else the composition, else the selection);
/// `mark` leaves its text composed, `insert` puts it in for good.
void TextService::ApplyOps(TfEditCookie cookie, ITfContext *context, const Json &ops, bool converting) {
    for (const Json &op : ops.items()) {
        bool mark = op["kind"].asString() == "mark";
        std::wstring text = Wide(op["text"].asString());
        const Json &replace = op["replace"];
        // A composition left in another field is finished there first.
        if (composition_ && compositionContext_ != context) EndComposition(cookie);

        ITfRange *target = nullptr;
        if (replace.isArray() && replace.size() == 2) {
            target = RangeAt(cookie, context, replace[0].asInt(), replace[1].asInt());
        }
        if (!target && composition_) composition_->GetRange(&target);
        if (!target) {
            TF_SELECTION selection = {};
            ULONG fetched = 0;
            if (SUCCEEDED(context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection, &fetched)) && fetched) {
                target = selection.range;
            }
        }
        if (!target) continue;

        if (mark) {
            if (!composition_) {
                ITfContextComposition *compose = nullptr;
                if (SUCCEEDED(context->QueryInterface(IID_ITfContextComposition, reinterpret_cast<void **>(&compose)))) {
                    if (SUCCEEDED(compose->StartComposition(cookie, target, static_cast<ITfCompositionSink *>(this),
                                                            &composition_)) && composition_) {
                        compositionContext_ = context;
                        compositionContext_->AddRef();
                    }
                    compose->Release();
                }
            } else {
                composition_->ShiftStart(cookie, target);
                composition_->ShiftEnd(cookie, target);
            }
            if (composition_) {
                ITfRange *range = nullptr;
                composition_->GetRange(&range);
                if (range) {
                    range->SetText(cookie, 0, text.c_str(), static_cast<LONG>(text.size()));
                    if (text.empty()) {
                        range->Release();
                        EndComposition(cookie);
                    } else {
                        ApplyAttributes(cookie, context, range, converting, op["clause"]);
                        MoveCaretToEnd(cookie, context, range);
                        range->Release();
                    }
                }
            }
        } else if (composition_) {
            composition_->ShiftStart(cookie, target);
            composition_->ShiftEnd(cookie, target);
            ITfRange *range = nullptr;
            composition_->GetRange(&range);
            if (range) {
                range->SetText(cookie, 0, text.c_str(), static_cast<LONG>(text.size()));
                ClearAttributes(cookie, context, range);
                MoveCaretToEnd(cookie, context, range);
                range->Release();
            }
            EndComposition(cookie);
        } else if (replace.isArray()) {
            target->SetText(cookie, 0, text.c_str(), static_cast<LONG>(text.size()));
            MoveCaretToEnd(cookie, context, target);
        } else {
            ITfInsertAtSelection *insert = nullptr;
            if (SUCCEEDED(context->QueryInterface(IID_ITfInsertAtSelection, reinterpret_cast<void **>(&insert)))) {
                ITfRange *inserted = nullptr;
                if (SUCCEEDED(insert->InsertTextAtSelection(cookie, 0, text.c_str(), static_cast<LONG>(text.size()),
                                                            &inserted)) && inserted) {
                    MoveCaretToEnd(cookie, context, inserted);
                    inserted->Release();
                }
                insert->Release();
            }
        }
        target->Release();
    }
}

/// The word being typed underlined; a phrase being converted as its reading (thin), with the clause
/// the candidates are for (`clause`, within the text) thick, as macOS draws its clauses.
void TextService::ApplyAttributes(TfEditCookie cookie, ITfContext *context, ITfRange *range, bool converting,
                                  const Json &clause) {
    ITfProperty *property = nullptr;
    if (FAILED(context->GetProperty(kGuidPropAttribute, &property)) || !property) return;
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_I4;
    bool clauses = clause.isArray() && clause.size() == 2 && clause[1].asInt() > 0;
    value.lVal = static_cast<LONG>(clauses ? attrConverted_ : converting ? attrTarget_ : attrInput_);
    property->SetValue(cookie, range, &value);
    if (clauses) {
        ITfRange *selected = nullptr;
        if (SUCCEEDED(range->Clone(&selected)) && selected) {
            LONG moved = 0;
            selected->Collapse(cookie, TF_ANCHOR_START);
            selected->ShiftEnd(cookie, clause[0].asInt() + clause[1].asInt(), &moved, nullptr);
            selected->ShiftStart(cookie, clause[0].asInt(), &moved, nullptr);
            value.lVal = static_cast<LONG>(attrTarget_);
            property->SetValue(cookie, selected, &value);
            selected->Release();
        }
    }
    property->Release();
}

void TextService::ClearAttributes(TfEditCookie cookie, ITfContext *context, ITfRange *range) {
    ITfProperty *property = nullptr;
    if (SUCCEEDED(context->GetProperty(kGuidPropAttribute, &property)) && property) {
        property->Clear(cookie, range);
        property->Release();
    }
}

STDMETHODIMP TextService::OnCompositionTerminated(TfEditCookie cookie, ITfComposition *composition) {
    // The app ended it (a click elsewhere): the text stays as it is, and the session starts afresh.
    if (composition_ && composition == composition_) {
        ITfRange *range = nullptr;
        if (compositionContext_ && SUCCEEDED(composition_->GetRange(&range)) && range) {
            ClearAttributes(cookie, compositionContext_, range);
            range->Release();
        }
        SafeRelease(composition_);
        SafeRelease(compositionContext_);
        Json request = Json::object();
        request.set("op", "terminated");
        Json response;
        host_.Request(request, response, 200);
    }
    return S_OK;
}

// MARK: Display attributes

void TextService::RegisterAttributes() {
    ITfCategoryMgr *categories = nullptr;
    if (FAILED(CoCreateInstance(kClsidTfCategoryMgr, nullptr, CLSCTX_INPROC_SERVER, kIID_ITfCategoryMgr,
                                reinterpret_cast<void **>(&categories)))) return;
    categories->RegisterGUID(kGuidAttrInput, &attrInput_);
    categories->RegisterGUID(kGuidAttrConverted, &attrConverted_);
    categories->RegisterGUID(kGuidAttrTarget, &attrTarget_);
    categories->Release();
}

STDMETHODIMP TextService::EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo **enumerator) {
    if (!enumerator) return E_INVALIDARG;
    *enumerator = new (std::nothrow) DisplayAttributeEnum();
    return *enumerator ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP TextService::GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo **info) {
    if (!info) return E_INVALIDARG;
    *info = DisplayAttributeInfo::For(guid);
    return *info ? S_OK : E_INVALIDARG;
}

// MARK: Menu

Json TextService::Menu() {
    Json request = Json::object();
    request.set("op", "menu");
    Json response;
    if (!host_.Request(request, response, 1000)) return Json::array();
    return response["reply"]["menu"];
}

void TextService::MenuSelect(const std::string &item) {
    Json request = Json::object();
    request.set("op", "menuSelect");
    request.set("item", item);
    Json response;
    host_.Request(request, response, 1000);
}

// MARK: The message window

bool TextService::CreateMessageWindow() {
    static ATOM atom = 0;
    if (!atom) {
        WNDCLASSEXW cls = {sizeof cls};
        cls.lpfnWndProc = WindowProc;
        cls.hInstance = g_instance;
        cls.lpszClassName = L"ArasoTipMessages";
        atom = RegisterClassExW(&cls);
        if (!atom && GetLastError() == ERROR_CLASS_ALREADY_EXISTS) atom = 1;
    }
    window_ = CreateWindowExW(0, L"ArasoTipMessages", L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, g_instance, nullptr);
    if (!window_) return false;
    SetWindowLongPtrW(window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    // The host may run at a lower integrity than an elevated app: let its message through.
    ChangeWindowMessageFilterEx(window_, PendingMessage(), MSGFLT_ALLOW, nullptr);
    return true;
}

void TextService::DestroyMessageWindow() {
    if (window_) {
        SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
        ::DestroyWindow(window_);
    }
    window_ = nullptr;
}

LRESULT CALLBACK TextService::WindowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == PendingMessage()) {
        auto *service = reinterpret_cast<TextService *>(GetWindowLongPtrW(window, GWLP_USERDATA));
        if (service) service->FetchPending();
        return 0;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

}  // namespace araso
