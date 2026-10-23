#include "LangBarButton.h"

#include "TextService.h"
#include "resource.h"

#include <new>

namespace araso {

namespace {
constexpr DWORD kSinkCookie = 0x41524153;  // 'ARAS'
}

LangBarButton::LangBarButton(TextService *service) : service_(service) {
    service_->AddRef();
    DllAddRef();
}

LangBarButton::~LangBarButton() {
    if (sink_) sink_->Release();
    service_->Release();
    DllRelease();
}

STDMETHODIMP LangBarButton::QueryInterface(REFIID riid, void **object) {
    if (!object) return E_INVALIDARG;
    *object = nullptr;
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, kIID_ITfLangBarItem) ||
        IsEqualIID(riid, kIID_ITfLangBarItemButton)) {
        *object = static_cast<ITfLangBarItemButton *>(this);
    } else if (IsEqualIID(riid, IID_ITfSource)) {
        *object = static_cast<ITfSource *>(this);
    }
    if (!*object) return E_NOINTERFACE;
    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) LangBarButton::AddRef() { return InterlockedIncrement(&references_); }

STDMETHODIMP_(ULONG) LangBarButton::Release() {
    LONG count = InterlockedDecrement(&references_);
    if (!count) delete this;
    return count;
}

STDMETHODIMP LangBarButton::GetInfo(TF_LANGBARITEMINFO *info) {
    if (!info) return E_INVALIDARG;
    info->clsidService = kClsidTextService;
    // The input mode item: Windows shows it in the taskbar's input indicator.
    info->guidItem = kGuidLbiInputMode;
    info->dwStyle = TF_LBI_STYLE_BTN_BUTTON | TF_LBI_STYLE_SHOWNINTRAY;
    info->ulSort = 0;
    lstrcpynW(info->szDescription, L"Araso", TF_LBI_DESC_MAXLEN);
    return S_OK;
}

STDMETHODIMP LangBarButton::GetStatus(DWORD *status) {
    if (!status) return E_INVALIDARG;
    *status = 0;
    return S_OK;
}

STDMETHODIMP LangBarButton::GetTooltipString(BSTR *tooltip) {
    if (!tooltip) return E_INVALIDARG;
    *tooltip = SysAllocString(L"Araso");
    return *tooltip ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP LangBarButton::GetText(BSTR *text) {
    if (!text) return E_INVALIDARG;
    *text = SysAllocString(L"Araso");
    return *text ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP LangBarButton::GetIcon(HICON *icon) {
    if (!icon) return E_INVALIDARG;
    int size = GetSystemMetrics(SM_CXSMICON);
    *icon = static_cast<HICON>(LoadImageW(g_instance, MAKEINTRESOURCEW(IDI_ARASO), IMAGE_ICON, size, size, 0));
    return *icon ? S_OK : E_FAIL;
}

void LangBarButton::Load(const Json &menu) {
    items_.clear();
    for (const Json &item : menu.items()) items_.push_back(item["id"].asString());
}

/// The input indicator clicks rather than asks for a menu: the menu is shown here, by the click.
STDMETHODIMP LangBarButton::OnClick(TfLBIClick, POINT point, const RECT *) {
    Json menu = service_->Menu();
    Load(menu);
    HMENU popup = CreatePopupMenu();
    if (!popup) return E_FAIL;
    UINT id = 1;
    for (const Json &item : menu.items()) {
        if (item["separator"].asBool()) {
            AppendMenuW(popup, MF_SEPARATOR, 0, nullptr);
        } else {
            UINT flags = MF_STRING;
            if (item["checked"].asBool()) flags |= MF_CHECKED;
            if (!item["enabled"].asBool(true) || item["id"].isNull()) flags |= MF_GRAYED;
            AppendMenuW(popup, flags, id, Wide(item["title"].asString()).c_str());
        }
        id++;
    }
    // A menu needs a window of this thread to belong to; it takes the foreground only while open.
    HWND owner = CreateWindowExW(WS_EX_TOOLWINDOW, L"STATIC", L"", WS_POPUP, point.x, point.y, 0, 0, nullptr, nullptr,
                                 g_instance, nullptr);
    if (owner) SetForegroundWindow(owner);
    UINT chosen = TrackPopupMenuEx(popup, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
                                   point.x, point.y, owner, nullptr);
    DestroyMenu(popup);
    if (owner) DestroyWindow(owner);
    if (chosen) OnMenuSelect(chosen);
    return S_OK;
}

STDMETHODIMP LangBarButton::InitMenu(ITfMenu *menu) {
    if (!menu) return E_INVALIDARG;
    Json items = service_->Menu();
    Load(items);
    UINT id = 1;
    for (const Json &item : items.items()) {
        DWORD flags = 0;
        if (item["separator"].asBool()) flags |= TF_LBMENUF_SEPARATOR;
        if (item["checked"].asBool()) flags |= TF_LBMENUF_CHECKED;
        if (!item["enabled"].asBool(true) || item["id"].isNull()) flags |= TF_LBMENUF_GRAYED;
        std::wstring title = Wide(item["title"].asString());
        menu->AddMenuItem(id, flags, nullptr, nullptr, title.c_str(), static_cast<ULONG>(title.size()), nullptr);
        id++;
    }
    return S_OK;
}

STDMETHODIMP LangBarButton::OnMenuSelect(UINT id) {
    if (id == 0 || id > items_.size() || items_[id - 1].empty()) return S_OK;
    service_->MenuSelect(items_[id - 1]);
    return S_OK;
}

STDMETHODIMP LangBarButton::AdviseSink(REFIID riid, IUnknown *sink, DWORD *cookie) {
    if (!sink || !cookie) return E_INVALIDARG;
    if (!IsEqualIID(riid, kIID_ITfLangBarItemSink)) return CONNECT_E_CANNOTCONNECT;
    if (sink_) return CONNECT_E_ADVISELIMIT;
    if (FAILED(sink->QueryInterface(kIID_ITfLangBarItemSink, reinterpret_cast<void **>(&sink_)))) {
        sink_ = nullptr;
        return E_NOINTERFACE;
    }
    *cookie = kSinkCookie;
    return S_OK;
}

STDMETHODIMP LangBarButton::UnadviseSink(DWORD cookie) {
    if (cookie != kSinkCookie || !sink_) return CONNECT_E_NOCONNECTION;
    sink_->Release();
    sink_ = nullptr;
    return S_OK;
}

}  // namespace araso
