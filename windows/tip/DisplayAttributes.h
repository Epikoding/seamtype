// How the composition is drawn: the word being typed underlined, as macOS underlines marked
// text, and while converting the reading thin with the clause the candidates are for thick.
#pragma once

#include "Tsf.h"

namespace araso {

class DisplayAttributeInfo final : public ITfDisplayAttributeInfo {
public:
    /// The attribute for `guid`, or nullptr.
    static DisplayAttributeInfo *For(REFGUID guid);
    /// Every attribute, in order (index 0, 1, 2).
    static DisplayAttributeInfo *At(ULONG index);
    static constexpr ULONG kCount = 3;

    STDMETHODIMP QueryInterface(REFIID riid, void **object) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    STDMETHODIMP GetGUID(GUID *guid) override;
    STDMETHODIMP GetDescription(BSTR *description) override;
    STDMETHODIMP GetAttributeInfo(TF_DISPLAYATTRIBUTE *attribute) override;
    STDMETHODIMP SetAttributeInfo(const TF_DISPLAYATTRIBUTE *) override { return E_NOTIMPL; }
    STDMETHODIMP Reset() override { return S_OK; }

private:
    DisplayAttributeInfo(const GUID &guid, const wchar_t *description, TF_DISPLAYATTRIBUTE attribute);
    ~DisplayAttributeInfo();

    LONG references_ = 1;
    GUID guid_;
    const wchar_t *description_;
    TF_DISPLAYATTRIBUTE attribute_;
};

class DisplayAttributeEnum final : public IEnumTfDisplayAttributeInfo {
public:
    DisplayAttributeEnum();

    STDMETHODIMP QueryInterface(REFIID riid, void **object) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    STDMETHODIMP Clone(IEnumTfDisplayAttributeInfo **clone) override;
    STDMETHODIMP Next(ULONG count, ITfDisplayAttributeInfo **infos, ULONG *fetched) override;
    STDMETHODIMP Reset() override;
    STDMETHODIMP Skip(ULONG count) override;

private:
    ~DisplayAttributeEnum();

    LONG references_ = 1;
    ULONG index_ = 0;
};

}  // namespace araso
