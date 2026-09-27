// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#include "chrome/browser/ui/cobble/cobble_identity.h"

#include <map>
#include <memory>
#include <string>
#include <utility>

#include "base/check.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "components/embedder_support/user_agent_utils.h"
#include "components/version_info/version_info.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "third_party/blink/public/common/user_agent/user_agent_metadata.h"
#include "url/gurl.h"

namespace {

struct IdentityPolicy {
  void* user_data = nullptr;
  CCSIdentityResolver resolver = nullptr;
  bool resolving = false;
};

using Policies = std::map<CCSContextRef, std::shared_ptr<IdentityPolicy>>;

Policies& ContextPolicies() {
  static base::NoDestructor<Policies> policies;
  return *policies;
}

std::shared_ptr<IdentityPolicy> PolicyFor(CCSContextRef context) {
  auto& policy = ContextPolicies()[context];
  if (!policy) {
    policy = std::make_shared<IdentityPolicy>();
  }
  return policy;
}

blink::UserAgentOverride IdentityFor(int32_t preset) {
  blink::UserAgentOverride identity;
  if (preset == 1 || preset == 2) {
    const std::string major = version_info::GetMajorVersionNumber();
    const bool phone = preset == 1;
    identity.ua_string_override =
        embedder_support::BuildUserAgentFromOSAndProduct(
            "Linux; Android 10; K",
            "Chrome/" + major + ".0.0.0" + (phone ? " Mobile" : ""));
    auto metadata = embedder_support::GetUserAgentMetadata();
    metadata.platform = "Android";
    metadata.platform_version = "10";
    metadata.architecture.clear();
    metadata.model = "K";
    metadata.bitness.clear();
    metadata.wow64 = false;
    metadata.mobile = phone;
    metadata.form_factors =
        {phone ? blink::kMobileFormFactor : blink::kTabletFormFactor};
    identity.ua_metadata_override = std::move(metadata);
  } else if (preset == 3) {
    identity.ua_string_override =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) "
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 "
        "Mobile/15E148 Safari/604.1";
  } else if (preset == 4) {
    identity.ua_string_override =
        "Mozilla/5.0 (iPad; CPU OS 26_0 like Mac OS X) "
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 "
        "Mobile/15E148 Safari/604.1";
  } else {
    // An empty override restores Chromium's native UA and client hints.
  }
  return identity;
}

class IdentityObserver final : public content::WebContentsObserver,
                               public content::WebContentsUserData<IdentityObserver> {
 public:
  ~IdentityObserver() override = default;

  void SetPolicy(std::shared_ptr<IdentityPolicy> policy) {
    policy_ = std::move(policy);
  }

  std::shared_ptr<IdentityPolicy> policy() const { return policy_; }

  void DidStartNavigation(content::NavigationHandle* handle) override {
    Apply(handle);
  }

  void DidRedirectNavigation(content::NavigationHandle* handle) override {
    Apply(handle);
  }

 private:
  friend class content::WebContentsUserData<IdentityObserver>;
  WEB_CONTENTS_USER_DATA_KEY_DECL();

  IdentityObserver(content::WebContents* contents,
                   std::shared_ptr<IdentityPolicy> policy)
      : content::WebContentsObserver(contents),
        content::WebContentsUserData<IdentityObserver>(*contents),
        policy_(std::move(policy)) {}

  void Apply(content::NavigationHandle* handle) {
    if (!handle->IsInPrimaryMainFrame() || handle->IsSameDocument()) {
      return;
    }

    int32_t preset = 0;
    const GURL& url = handle->GetURL();
    if (url.SchemeIsHTTPOrHTTPS() && policy_ && policy_->resolver &&
        !policy_->resolving) {
      std::shared_ptr<IdentityPolicy> policy = policy_;
      const auto resolver = policy->resolver;
      void* user_data = policy->user_data;
      base::WeakPtr<IdentityObserver> alive = weak_factory_.GetWeakPtr();
      policy->resolving = true;
      const std::string address = url.spec();
      const int32_t selected = resolver(user_data, address.c_str());
      policy->resolving = false;
      if (!alive) {
        return;
      }
      if (policy->resolver == resolver && policy->user_data == user_data &&
          selected >= 0 && selected <= 4) {
        preset = selected;
      }
    }

    base::WeakPtr<IdentityObserver> alive = weak_factory_.GetWeakPtr();
    web_contents()->SetUserAgentOverride(IdentityFor(preset), preset != 0);
    if (alive) {
      handle->SetIsOverridingUserAgent(preset != 0);
    }
  }

  std::shared_ptr<IdentityPolicy> policy_;
  base::WeakPtrFactory<IdentityObserver> weak_factory_{this};
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(IdentityObserver);

}  // namespace

namespace cobble_chromium {

void AttachIdentityPolicy(CCSContextRef context, content::WebContents* contents) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!context || !contents) {
    return;
  }
  auto policy = PolicyFor(context);
  IdentityObserver::GetOrCreateForWebContents(contents, policy)
      ->SetPolicy(std::move(policy));
}

void InheritIdentityPolicy(content::WebContents* opener,
                           content::WebContents* popup) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!opener || !popup) {
    return;
  }
  auto* parent = IdentityObserver::FromWebContents(opener);
  if (!parent) {
    return;
  }
  IdentityObserver::GetOrCreateForWebContents(popup, parent->policy());
  popup->SetUserAgentOverride(opener->GetUserAgentOverride(), true);
}

void ClearContextIdentityPolicy(CCSContextRef context) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto entry = ContextPolicies().find(context);
  if (entry == ContextPolicies().end()) {
    return;
  }
  entry->second->resolver = nullptr;
  entry->second->user_data = nullptr;
  ContextPolicies().erase(entry);
}

}  // namespace cobble_chromium

extern "C" void CCSContextSetIdentityResolver(CCSContextRef context,
                                                 void* user_data,
                                                 CCSIdentityResolver callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!context) {
    return;
  }
  auto policy = PolicyFor(context);
  policy->user_data = callback ? user_data : nullptr;
  policy->resolver = callback;
}
