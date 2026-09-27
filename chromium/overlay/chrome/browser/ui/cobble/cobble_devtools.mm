// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#include "chrome/browser/ui/cobble/cobble_devtools.h"

#import <Cocoa/Cocoa.h>

#include <algorithm>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/auto_reset.h"
#include "base/memory/raw_ptr.h"
#include "base/process/process.h"
#include "base/task/single_thread_task_runner.h"
#include "base/uuid.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/cobble/cobble_chromium.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "content/public/browser/file_select_listener.h"
#include "content/public/browser/javascript_dialog_manager.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/base_window.h"

struct CCSDevToolsSession final : public content::WebContentsObserver {
  CCSDevToolsSession(CCSPageRef inspected_page,
                     content::WebContents* inspected_contents,
                     content::WebContents* frontend_contents,
                     Profile* session_profile,
                     bool retained_private_profile)
      : content::WebContentsObserver(frontend_contents),
        page(inspected_page),
        inspected(inspected_contents),
        frontend(frontend_contents),
        profile(session_profile),
        retained_private_profile(retained_private_profile) {}

  void WebContentsDestroyed() override;
  void PrimaryMainFrameRenderProcessGone(
      base::TerminationStatus status) override;
  void Retire();

  CCSPageRef page = nullptr;
  raw_ptr<content::WebContents> inspected = nullptr;
  raw_ptr<content::WebContents> frontend = nullptr;
  raw_ptr<Profile> profile = nullptr;
  bool retained_private_profile = false;
  bool closing = false;
  bool closed = false;
  bool released = false;
  bool notifying_closed = false;
};

namespace {

struct PendingHost {
  raw_ptr<content::WebContents> inspected = nullptr;
  std::string host_window_id;
};

std::vector<std::unique_ptr<CCSDevToolsSession>>& Sessions() {
  static auto* sessions =
      new std::vector<std::unique_ptr<CCSDevToolsSession>>();
  return *sessions;
}

std::vector<PendingHost>& PendingHosts() {
  static auto* hosts = new std::vector<PendingHost>();
  return *hosts;
}

CCSDevToolsSession* FindSession(CCSDevToolsSessionRef candidate) {
  for (const auto& session : Sessions()) {
    if (session.get() == candidate) {
      return session.get();
    }
  }
  return nullptr;
}

CCSDevToolsSession* SessionForPage(CCSPageRef page) {
  for (const auto& session : Sessions()) {
    if (!session->closed && session->page == page) {
      return session.get();
    }
  }
  return nullptr;
}

void DeleteReleasedSession(CCSDevToolsSessionRef candidate) {
  std::erase_if(Sessions(), [candidate](const auto& session) {
    return session.get() == candidate && session->released && session->closed;
  });
}

uint8_t BeginClose(CCSDevToolsSession* session) {
  if (!session || session->closed || session->closing || !session->frontend) {
    return 0;
  }
  session->closing = true;
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(
          session->frontend);
  if (browser && browser->GetWindow()) {
    browser->GetWindow()->Close();
  } else {
    session->frontend->ClosePage();
  }
  return 1;
}

void CancelAllForShutdown() {
  std::vector<CCSDevToolsSession*> sessions;
  for (const auto& session : Sessions()) {
    sessions.push_back(session.get());
  }
  for (CCSDevToolsSession* session : sessions) {
    if (FindSession(session)) {
      session->Retire();
    }
  }
  PendingHosts().clear();
}

class DevToolsDialogManager final
    : public content::JavaScriptDialogManager {
 public:
  void RunJavaScriptDialog(content::WebContents*,
                           content::RenderFrameHost*,
                           content::JavaScriptDialogType,
                           const std::u16string&,
                           const std::u16string&,
                           DialogClosedCallback,
                           bool* suppressed) override {
    *suppressed = true;
  }

  void RunBeforeUnloadDialog(content::WebContents*,
                             content::RenderFrameHost*,
                             bool,
                             DialogClosedCallback callback) override {
    std::move(callback).Run(true, {});
  }

  bool HandleJavaScriptDialog(content::WebContents*,
                              bool,
                              const std::u16string*) override {
    return false;
  }

  void CancelDialogs(content::WebContents*, bool) override {}
};

}  // namespace

void CCSDevToolsSession::WebContentsDestroyed() {
  Retire();
}

void CCSDevToolsSession::PrimaryMainFrameRenderProcessGone(
    base::TerminationStatus) {
  BeginClose(this);
}

void CCSDevToolsSession::Retire() {
  if (closed) {
    return;
  }
  Observe(nullptr);
  std::erase_if(PendingHosts(), [this](const PendingHost& pending) {
    return pending.inspected == inspected;
  });
  inspected = nullptr;
  frontend = nullptr;
  closed = true;
  closing = false;
  notifying_closed = true;
  if (cobble_chromium::Client().devtools_session_closed) {
    cobble_chromium::Client().devtools_session_closed(
        cobble_chromium::Client().user_data, this);
  }
  notifying_closed = false;
  if (retained_private_profile) {
    retained_private_profile = false;
    cobble_chromium::ReleasePrivateProfileLease(profile);
  }
  profile = nullptr;
  if (released) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&DeleteReleasedSession, this));
  }
}

namespace cobble_chromium {

bool IsOwnedDevTools(content::WebContents* contents) {
  if (!contents) {
    return false;
  }
  if (std::ranges::any_of(Sessions(), [contents](const auto& session) {
    return !session->closed && session->frontend == contents;
  })) {
    return true;
  }
  DevToolsWindow* window = DevToolsWindow::AsDevToolsWindow(contents);
  return window && HasPendingOwnedDevTools(window->GetInspectedWebContents());
}

bool HasPendingOwnedDevTools(content::WebContents* inspected) {
  return inspected &&
         std::ranges::any_of(PendingHosts(), [inspected](const PendingHost& host) {
           return host.inspected == inspected;
         });
}

BrowserWindowInterface* CreateOwnedDevToolsBrowser(
    Profile* profile,
    content::WebContents* inspected) {
  auto iterator = std::ranges::find(PendingHosts(), inspected,
                                    &PendingHost::inspected);
  if (iterator == PendingHosts().end()) {
    return nullptr;
  }
  std::string host_window_id = std::move(iterator->host_window_id);
  PendingHosts().erase(iterator);
  // The standard factory still creates CobbleBrowserWindow. This scope only
  // binds that Browser to the client-owned inspector NSWindow.
  base::AutoReset<std::string> pending(&PendingHostWindowIDForDevTools(),
                                       std::move(host_window_id));
  return CreateBrowserWindow(
      BrowserWindowCreateParams::CreateForDevTools(profile));
}

content::JavaScriptDialogManager* GetDevToolsJavaScriptDialogManager() {
  static auto* manager = new DevToolsDialogManager();
  return manager;
}

void CloseDevToolsForPage(CCSPageRef page) {
  BeginClose(SessionForPage(page));
}

}  // namespace cobble_chromium

extern "C" CCSDevToolsSessionRef CCSPageOpenDevTools(
    CCSPageRef page,
    const char* host_window_id_utf8) {
  content::WebContents* inspected = cobble_chromium::PageWebContents(page);
  if (!inspected || cobble_chromium::IsStopping() || SessionForPage(page) ||
      cobble_chromium::PageHasPendingPromptOrMedia(page) ||
      DevToolsWindow::GetInstanceForInspectedWebContents(inspected)) {
    return nullptr;
  }
  const std::string host_window_id = base::Uuid::ParseCaseInsensitive(
      host_window_id_utf8 ? host_window_id_utf8 : "").AsLowercaseString();
  if (host_window_id.empty() || !cobble_chromium::Client().host_window ||
      !cobble_chromium::Client().host_window(
          cobble_chromium::Client().user_data, host_window_id.c_str(), nullptr)) {
    return nullptr;
  }
  if (cobble_chromium::PageForWebContents(inspected) != page) {
    return nullptr;
  }
  PendingHosts().push_back({inspected, host_window_id});
  DevToolsWindow::OpenDevToolsWindow(inspected,
                                     DevToolsOpenedByAction::kUnknown);
  DevToolsWindow* window =
      DevToolsWindow::GetInstanceForInspectedWebContents(inspected);
  content::WebContents* frontend =
      window ? window->GetDevToolsWebContents() : nullptr;
  if (!frontend) {
    std::erase_if(PendingHosts(), [inspected](const PendingHost& pending) {
      return pending.inspected == inspected;
    });
    return nullptr;
  }
  Profile* profile = Profile::FromBrowserContext(inspected->GetBrowserContext());
  const bool retained_private_profile =
      cobble_chromium::RetainPrivateProfileLease(profile);
  auto session =
      std::make_unique<CCSDevToolsSession>(page, inspected, frontend, profile,
                                          retained_private_profile);
  CCSDevToolsSession* result = session.get();
  Sessions().push_back(std::move(session));
  cobble_chromium::RegisterShutdownCallback(&CancelAllForShutdown);
  return result;
}

extern "C" void* CCSDevToolsSessionView(CCSDevToolsSessionRef candidate) {
  CCSDevToolsSession* session = FindSession(candidate);
  if (!session || session->closed || !session->frontend) {
    return nullptr;
  }
  NSView* view = session->frontend->GetNativeView().GetNativeNSView();
  return (__bridge void*)view;
}

extern "C" void CCSDevToolsSessionFocus(CCSDevToolsSessionRef candidate) {
  CCSDevToolsSession* session = FindSession(candidate);
  if (session && !session->closed && session->frontend) {
    session->frontend->SetInitialFocus();
  }
}

extern "C" void CCSDevToolsSessionSetVisible(
    CCSDevToolsSessionRef candidate,
    uint8_t visible) {
  CCSDevToolsSession* session = FindSession(candidate);
  if (!session || session->closed || !session->frontend) {
    return;
  }
  if (visible) {
    session->frontend->WasShown();
  } else {
    session->frontend->WasHidden();
  }
}

extern "C" uint8_t CCSDevToolsSessionClose(
    CCSDevToolsSessionRef candidate) {
  return BeginClose(FindSession(candidate));
}

extern "C" uint8_t CCSDevToolsSessionIsClosed(
    CCSDevToolsSessionRef candidate) {
  CCSDevToolsSession* session = FindSession(candidate);
  return !session || session->closed;
}

extern "C" void CCSDevToolsSessionRelease(
    CCSDevToolsSessionRef candidate) {
  CCSDevToolsSession* session = FindSession(candidate);
  if (!session || session->released) {
    return;
  }
  session->released = true;
  if (!session->closed) {
    CCSDevToolsSessionClose(session);
  } else if (!session->notifying_closed) {
    DeleteReleasedSession(session);
  }
}
