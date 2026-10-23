// Araso's button in the taskbar's input indicator (and the language bar): its menu is the macOS
// input menu, built by the host each time it opens.
#pragma once

#include "Tsf.h"

#include <string>
#include <vector>

namespace araso {

class TextService;

class LangBarButton final : public ITfLangBarItemButton, public ITfSource {
public:
    explicit LangBarButton(TextService *service);

    STDMETHODIMP QueryInterface(REFIID riid, void **object) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    // ITfLangBarItem
    STDMETHODIMP GetInfo(TF_LANGBARITEMINFO *info) override;
    STDMETHODIMP GetStatus(DWORD *status) override;
    STDMETHODIMP Show(BOOL) override { return S_OK; }
    STDMETHODIMP GetTooltipString(BSTR *tooltip) override;

    // ITfLangBarItemButton
    STDMETHODIMP OnClick(TfLBIClick click, POINT point, const RECT *area) override;
    STDMETHODIMP InitMenu(ITfMenu *menu) override;
    STDMETHODIMP OnMenuSelect(UINT id) override;
    STDMETHODIMP GetIcon(HICON *icon) override;
    STDMETHODIMP GetText(BSTR *text) override;

    // ITfSource
    STDMETHODIMP AdviseSink(REFIID riid, IUnknown *sink, DWORD *cookie) override;
    STDMETHODIMP UnadviseSink(DWORD cookie) override;

private:
    ~LangBarButton();

    LONG references_ = 1;
    TextService *service_;
    ITfLangBarItemSink *sink_ = nullptr;
    /// The ids of the menu last built, by position (`id - 1`).
    std::vector<std::string> items_;

    void Load(const Json &menu);
};

}  // namespace araso
