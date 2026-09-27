// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#include "chrome/browser/ui/cobble/cobble_extension_install_prompt.h"

#include <algorithm>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/no_destructor.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/extensions/extension_install_prompt_show_params.h"
#include "chrome/browser/ui/cobble/cobble_chromium.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/install_prompt_data.h"
#include "extensions/common/permissions/permission_set.h"
#include "extensions/common/permissions/permissions_data.h"

struct CCSExtensionInstallRequest {
  uint64_t id;
  CCSPageRef page;
  base::WeakPtr<content::WebContents> contents;
  ExtensionInstallPrompt::DoneCallback callback;
  std::unique_ptr<extensions::InstallPromptData> prompt;
  std::string extension_id;
  std::string name;
  std::string source_url;
  std::string title;
  std::string permissions_heading;
  std::vector<std::string> warnings;
  std::vector<const char*> warning_pointers;
};

namespace {

using Request = CCSExtensionInstallRequest;

struct Requests {
  uint64_t next_id = 1;
  std::vector<std::unique_ptr<Request>> pending;
};

Requests& State() {
  static base::NoDestructor<Requests> state;
  return *state;
}

Request* Find(CCSExtensionInstallRequestRef handle) {
  for (const auto& request : State().pending)
    if (request.get() == handle) return request.get();
  return nullptr;
}

void Finish(Request* request, bool accept, bool notify_cancelled) {
  auto& pending = State().pending;
  auto found = std::find_if(pending.begin(), pending.end(),
                            [request](const auto& item) {
                              return item.get() == request;
                            });
  if (found == pending.end()) return;
  std::unique_ptr<Request> owned = std::move(*found);
  pending.erase(found);
  if (notify_cancelled &&
      cobble_chromium::Client().extension_install_cancelled) {
    cobble_chromium::Client().extension_install_cancelled(
        cobble_chromium::Client().user_data, owned.get(), owned->id);
  }
  // A Store install with requested hosts must never become active with broad
  // access because a feature flag or extension type disabled withholding.
  if (accept && owned->prompt->type() ==
                    extensions::InstallPromptData::INSTALL_PROMPT &&
      !owned->prompt->extension()->permissions_data()->active_permissions()
           .effective_hosts().is_empty() &&
      !owned->prompt->ShouldWithheldPermissionsOnDialogAccept()) {
    accept = false;
  }
  if (accept) {
    owned->prompt->OnDialogAccepted();
  } else {
    owned->prompt->OnDialogCanceled();
  }
  const auto result = !accept
      ? ExtensionInstallPrompt::Result::USER_CANCELED
      : owned->prompt->ShouldWithheldPermissionsOnDialogAccept()
          ? ExtensionInstallPrompt::Result::ACCEPTED_WITH_WITHHELD_PERMISSIONS
          : ExtensionInstallPrompt::Result::ACCEPTED;
  std::move(owned->callback).Run(
      ExtensionInstallPrompt::DoneCallbackPayload(result));
}

void CancelAllForShutdown() {
  while (!State().pending.empty())
    Finish(State().pending.front().get(), false, true);
}

}  // namespace

namespace cobble_chromium {

void ShowExtensionInstallPrompt(
    std::unique_ptr<ExtensionInstallPromptShowParams> show_params,
    ExtensionInstallPrompt::DoneCallback callback,
    std::unique_ptr<extensions::InstallPromptData> prompt) {
  content::WebContents* contents = show_params->GetParentWebContents();
  CCSPageRef page = contents ? PageForWebContents(contents) : nullptr;
  if (!page || !PageAcceptsPromptResult(page, contents) ||
      !Client().extension_install_requested || !prompt->extension()) {
    prompt->OnDialogCanceled();
    std::move(callback).Run(ExtensionInstallPrompt::DoneCallbackPayload(
        ExtensionInstallPrompt::Result::USER_CANCELED));
    return;
  }

  auto request = std::make_unique<Request>();
  request->id = State().next_id++;
  request->page = page;
  request->contents = contents->GetWeakPtr();
  request->callback = std::move(callback);
  request->extension_id = prompt->extension()->id();
  request->name = prompt->extension()->name();
  request->source_url = contents->GetLastCommittedURL().spec();
  request->title = base::UTF16ToUTF8(prompt->GetDialogTitle());
  request->permissions_heading =
      base::UTF16ToUTF8(prompt->GetPermissionsHeading());
  for (size_t i = 0; i < prompt->GetPermissionCount(); ++i)
    request->warnings.push_back(base::UTF16ToUTF8(prompt->GetPermission(i)));
  for (const std::string& warning : request->warnings)
    request->warning_pointers.push_back(warning.c_str());
  request->prompt = std::move(prompt);
  Request* handle = request.get();
  State().pending.push_back(std::move(request));
  CCSExtensionInstallRequestV1 value = {
      .struct_size = sizeof(CCSExtensionInstallRequestV1),
      .request_id = handle->id,
      .extension_id_utf8 = handle->extension_id.c_str(),
      .name_utf8 = handle->name.c_str(),
      .source_url_utf8 = handle->source_url.c_str(),
      .title_utf8 = handle->title.c_str(),
      .permissions_heading_utf8 = handle->permissions_heading.c_str(),
      .permission_warnings_utf8 = handle->warning_pointers.data(),
      .permission_warning_count = handle->warning_pointers.size(),
      .can_withhold_host_permissions = static_cast<uint8_t>(
          handle->prompt->ShouldWithheldPermissionsOnDialogAccept()),
      .requests_host_permissions = static_cast<uint8_t>(
          !handle->prompt->extension()->permissions_data()
               ->active_permissions().effective_hosts().is_empty()),
  };
  RegisterShutdownCallback(&CancelAllForShutdown);
  Client().extension_install_requested(Client().user_data, page, handle,
                                       &value);
}

bool PageHasPendingExtensionInstallPrompt(content::WebContents* contents) {
  for (const auto& request : State().pending)
    if (request->contents.get() == contents) return true;
  return false;
}

void CancelExtensionInstallPromptsForPage(content::WebContents* contents) {
  std::vector<Request*> matches;
  for (const auto& request : State().pending)
    if (request->contents.get() == contents) matches.push_back(request.get());
  for (Request* request : matches) Finish(request, false, true);
}

}  // namespace cobble_chromium

extern "C" uint8_t CCSExtensionInstallResolve(
    CCSExtensionInstallRequestRef handle, uint8_t accept) {
  Request* request = Find(handle);
  if (!request) return 0;
  const bool page_is_live = request->contents &&
      cobble_chromium::PageAcceptsPromptResult(request->page,
                                                request->contents.get());
  Finish(request, accept && page_is_live, false);
  return 1;
}
