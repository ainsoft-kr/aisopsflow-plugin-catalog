{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module PluginCatalogServer.Handler.Admin
  ( getAdminLoginR
  , postAdminLoginR
  , postAdminLogoutR
  , getAdminDashboardR
  , getAdminSummaryR
  , getAdminPluginsR
  , getAdminUsersR
  , getAdminActivityR
  , getAdminResolveR
  , getAdminAuditR
  , getAdminVersionDetailR
  , postAdminCreateUserR
  , postAdminToggleUserActiveR
  , postAdminResetUserPasswordR
  , postAdminUpdateUserRoleR
  , postAdminPublishR
  , postAdminPromoteR
  , postAdminDeactivateVersionR
  , postAdminDeleteVersionR
  ) where

import Data.Aeson (Value)
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Aeson ((.:))
import Data.Maybe (fromMaybe)
import qualified Data.Text.Encoding as TE
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.Encoding as TL
import Database.Persist
import Control.Monad ((>=>))
import Data.ByteString (ByteString)
import Data.List (nub)
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Clock (addUTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Network.HTTP.Types.Header (hUserAgent)
import Network.Wai (remoteHost)
import PluginCatalogServer.Auth (generateSessionToken, hashPassword, verifyPassword)
import PluginCatalogServer.Domain.Resolve
import PluginCatalogServer.Foundation
import PluginCatalogServer.Handler.Publish
import PluginCatalogServer.Model
import PluginCatalogServer.Settings
  ( appBootstrapAdminUsername
  , appSeedAdminPassword
  , appSeedOwnerPassword
  , appSeedPublisherPassword
  , appSeedViewerPassword
  , makeAbsoluteUrl
  , shouldUseSecureCookies
  )
import Text.Blaze.Html.Renderer.Text (renderHtml)
import Web.Cookie (defaultSetCookie, sameSiteLax, setCookieHttpOnly, setCookieName, setCookiePath, setCookieSameSite, setCookieSecure, setCookieValue)
import Yesod

data AdminVersionRow = AdminVersionRow
  { avrVersion :: Text
  , avrPlatform :: Text
  , avrRuntime :: Text
  , avrStatus :: Text
  , avrBadges :: [Text]
  , avrDetailHref :: Text
  }

data AdminPluginRow = AdminPluginRow
  { aprName :: Text
  , aprPublisher :: Text
  , aprLatestVersion :: Maybe Text
  , aprChannels :: [(Text, Text)]
  , aprVersions :: [AdminVersionRow]
  }

data AdminSummary = AdminSummary
  { asPluginCount :: Int
  , asActiveVersionCount :: Int
  , asChannelCount :: Int
  }

data AdminPluginFilters = AdminPluginFilters
  { apfName :: Maybe Text
  , apfStatus :: Maybe Text
  , apfChannel :: Maybe Text
  }

data Pagination = Pagination
  { pgPage :: Int
  , pgPageSize :: Int
  , pgTotalItems :: Int
  , pgTotalPages :: Int
  }

data AdminAuditEntry = AdminAuditEntry
  { aaeAction :: Text
  , aaeActor :: Maybe Text
  , aaeTarget :: Text
  , aaeDetail :: Maybe Text
  , aaeCreatedAt :: Text
  }

data AdminSection
  = AdminSectionSummary
  | AdminSectionPlugins
  | AdminSectionUsers
  | AdminSectionActivity
  | AdminSectionResolve
  deriving (Eq)

data AdminPermission
  = AdminPermissionManagePlugins
  | AdminPermissionManageUsers

data AdminUserRow = AdminUserRow
  { aurUsername :: Text
  , aurDisplayName :: Text
  , aurRole :: Text
  , aurIsActive :: Bool
  , aurLastLoginAt :: Maybe Text
  , aurCreatedAt :: Text
  }

getAdminLoginR :: Handler Html
getAdminLoginR = do
  app <- getYesod
  alreadyAuthed <- hasValidAdminSession
  if alreadyAuthed
    then redirect AdminDashboardR
    else do
      flashMessage <- getMessage
      adminUserCount <- runDB $ count ([] :: [Filter AdminUser])
      let bootstrapConfigured = maybe False (not . T.null) (appBootstrapAdminUsername (appSettings app))
          roleSeedsConfigured =
            any
              (maybe False (not . T.null))
              [ appSeedOwnerPassword (appSettings app)
              , appSeedAdminPassword (appSettings app)
              , appSeedPublisherPassword (appSettings app)
              , appSeedViewerPassword (appSettings app)
              ]
          loginModeText :: Text
          loginModeText =
            if shouldUseSecureCookies (appSettings app)
              then "User account login is enabled. Session uses an HttpOnly secure cookie."
              else "User account login is enabled. Session uses an HttpOnly cookie."
          bootstrapText :: Text
          bootstrapText =
            if adminUserCount > 0
              then "Sign in with your admin username and password."
              else
                if bootstrapConfigured || roleSeedsConfigured
                  then "No admin users exist yet. Bootstrap or role seed accounts will be created when the server starts with the configured credentials."
                  else "No admin users exist yet. Configure bootstrap admin credentials or role seed passwords and restart the server."
      defaultLayout $ do
        setTitle "Plugin Catalog Admin Login"
        toWidget
          [hamlet|
            <style>
              body { font-family: Helvetica, Arial, sans-serif; margin: 0; background: #f4f6f8; color: #16202a; }
              .login-shell { min-height: 100vh; display: grid; place-items: center; padding: 24px; }
              .login-card { width: min(420px, 100%); background: white; border-radius: 14px; padding: 24px; box-shadow: 0 10px 28px rgba(15, 23, 42, 0.10); }
              h1 { margin-top: 0; }
              label { display: block; font-size: 13px; font-weight: 700; margin: 10px 0 4px; }
              input { width: 100%; box-sizing: border-box; padding: 10px 12px; border: 1px solid #cfd8e3; border-radius: 8px; font-size: 14px; }
              button { margin-top: 14px; width: 100%; padding: 10px 14px; border: 0; border-radius: 8px; background: #14532d; color: white; font-weight: 700; cursor: pointer; text-align: center; }
              .flash { margin-bottom: 16px; padding: 12px 14px; border-radius: 8px; }
              .flash.success { background: #dcfce7; color: #14532d; }
              .flash.error { background: #fee2e2; color: #991b1b; }
              .meta { color: #475569; font-size: 14px; }
          |]
        [whamlet|
          <div .login-shell>
            <section .login-card>
              <h1>Admin Login
              <div .meta>#{loginModeText}
              <div .meta>#{bootstrapText}
              $maybe message <- flashMessage
                <div .flash .#{flashClass message}>#{flashBody message}
              <form method=post action=@{AdminLoginR}>
                <label for=admin-username>Username
                <input #admin-username type=text name=username placeholder="admin" autofocus required>
                <label for=admin-password>Password
                <input #admin-password type=password name=password required>
                <button type=submit>Sign In
        |]

postAdminLoginR :: Handler Html
postAdminLoginR = do
  app <- getYesod
  username <- runInputPost $ ireq textField "username"
  password <- runInputPost $ ireq textField "password"
  let normalizedUsername = T.strip username
  if T.null normalizedUsername
    then do
      setMessage (toHtml ("ERROR: Username is required." :: Text))
      redirect AdminLoginR
    else do
      maybeUser <- runDB $ getBy (UniqueAdminUsername normalizedUsername)
      case maybeUser of
        Nothing -> do
          setMessage (toHtml ("ERROR: Invalid username or password." :: Text))
          redirect AdminLoginR
        Just (Entity userId userRow)
          | not (adminUserIsActive userRow) -> do
              setMessage (toHtml ("ERROR: This account is inactive." :: Text))
              redirect AdminLoginR
          | not (verifyPassword password (adminUserPasswordHash userRow)) -> do
              setMessage (toHtml ("ERROR: Invalid username or password." :: Text))
              redirect AdminLoginR
          | otherwise -> do
              now <- liftIO getCurrentTime
              sessionToken <- liftIO generateSessionToken
              let expiry = addUTCTime (60 * 60 * 24 * 7) now
              runDB $
                insert_
                  AdminSession
                    { adminSessionAdminUserId = userId
                    , adminSessionSessionToken = sessionToken
                    , adminSessionCreatedAt = now
                    , adminSessionExpiresAt = expiry
                    }
              runDB $
                update
                  userId
                  [ AdminUserLastLoginAt =. Just now
                  , AdminUserUpdatedAt =. now
                  ]
              setCookie $
                defaultSetCookie
                  { setCookieName = adminSessionCookieName
                  , setCookieValue = TE.encodeUtf8 sessionToken
                  , setCookiePath = Just "/"
                  , setCookieHttpOnly = True
                  , setCookieSameSite = Just sameSiteLax
                  , setCookieSecure = shouldUseSecureCookies (appSettings app)
                  }
              logAdminActionWithActor (Just (adminUserDisplayName userRow)) "login" "admin" Nothing
              setMessage (toHtml ("SUCCESS: Admin login successful." :: Text))
              redirect AdminDashboardR

postAdminLogoutR :: Handler Html
postAdminLogoutR = do
  requireAdminAuth
  token <- lookupCookie adminSessionCookieText
  actor <- currentAdminActor
  case normalize token of
    Just sessionToken -> runDB $ deleteWhere [AdminSessionSessionToken ==. sessionToken]
    Nothing -> pure ()
  deleteCookie adminSessionCookieText "/"
  logAdminActionWithActor actor "logout" "admin" Nothing
  setMessage (toHtml ("SUCCESS: Signed out." :: Text))
  redirect AdminLoginR

getAdminDashboardR :: Handler Html
getAdminDashboardR = redirect AdminSummaryR

getAdminSummaryR :: Handler Html
getAdminSummaryR = do
  requireAdminAuth
  flashMessage <- getMessage
  plugins <- loadAdminPlugins
  recentAudit <- loadRecentAuditEntries
  let summary = buildSummary plugins
  adminLayout AdminSectionSummary flashMessage
    [whamlet|
      <section .card>
        <h2>Summary
        <div .summary-grid>
          <div .summary-card>
            <div .meta>Plugins
            <strong>#{show (asPluginCount summary)}
          <div .summary-card>
            <div .meta>Active Versions
            <strong>#{show (asActiveVersionCount summary)}
          <div .summary-card>
            <div .meta>Channels
            <strong>#{show (asChannelCount summary)}
      <section .card>
        <h2>Recent Admin Activity
        <div .meta>Latest 10 actions are shown here.
        <a .link-button href=@{AdminActivityR}>Open Full Activity
        ^{auditEntriesWidget recentAudit}
    |]

getAdminPluginsR :: Handler Html
getAdminPluginsR = do
  requireAdminAuth
  flashMessage <- getMessage
  plugins <- loadAdminPlugins
  canManagePlugins <- hasAdminPermission AdminPermissionManagePlugins
  filterName <- runInputGet $ iopt textField "plugin"
  filterStatus <- runInputGet $ iopt textField "status"
  filterChannel <- runInputGet $ iopt textField "filter_channel"
  pageParam <- runInputGet $ iopt intField "page"
  openPublish <- runInputGet $ iopt textField "open_publish"
  let pluginFilters = AdminPluginFilters filterName filterStatus filterChannel
      filteredPluginsAll =
        attachPluginFilters pluginFilters $
          applyPluginFilters (normalize filterName) (normalize filterStatus) (normalize filterChannel) plugins
      pagination = paginate 10 (pageParam) filteredPluginsAll
      filteredPlugins = pageItems pagination filteredPluginsAll
      availableChannels = listKnownChannels plugins
      publishModalOpen = normalize openPublish == Just "1"
      pageFlash = if publishModalOpen then Nothing else flashMessage
  adminLayout AdminSectionPlugins pageFlash
    [whamlet|
      <section .card>
        <div .section-header>
          <div>
            <h2>Plugins
            <div .meta>Filter plugins, inspect versions, promote channels, or open the publish modal.
          $if canManagePlugins
            <button type=button .secondary data-modal-open="publish-modal">Publish Plugin
        <form method=get action=@{AdminPluginsR} .toolbar>
          <div .field>
            <label for=plugin-filter>Plugin Name
            <input #plugin-filter type=text name=plugin value=#{fromMaybeText filterName} placeholder="http-client">
          <div .field>
            <label for=status-filter>Status
            <input #status-filter type=text name=status value=#{fromMaybeText filterStatus} placeholder="active">
          <div .field>
            <label for=channel-filter>Channel
            <input #channel-filter type=text name=filter_channel value=#{fromMaybeText filterChannel} list="known-channels" placeholder="stable">
            <datalist #known-channels>
              $forall knownChannel <- availableChannels
                <option value=#{knownChannel}>
          <div .field>
            <button .secondary type=submit>Filter
      <section .card>
        $if null filteredPlugins
          <div .meta>No plugins matched the current filters.
        $else
          $forall plugin <- filteredPlugins
            ^{pluginCardWidget plugin pluginFilters canManagePlugins}
          ^{paginationWidget pluginFilters pagination}
      $if canManagePlugins
        ^{publishModalWidget pluginFilters publishModalOpen flashMessage}
    |]

getAdminUsersR :: Handler Html
getAdminUsersR = do
  requireAdminPermission AdminPermissionManageUsers
  flashMessage <- getMessage
  currentUser <- requireCurrentAdminUserEntity
  users <- loadAdminUsers
  let currentUsername = adminUserUsername (entityVal currentUser)
  adminLayout AdminSectionUsers flashMessage
    [whamlet|
      <section .card>
        <div .section-header>
          <div>
            <h2>Users
            <div .meta>Create users, assign roles, deactivate accounts, or reset passwords.
        <div .meta>Active role model: owner, admin, publisher, viewer
      <section .card>
        <h2>Create User
        <form method=post action=@{AdminCreateUserR}>
          <label for=create-username>Username
          <input #create-username type=text name=username required>
          <label for=create-display-name>Display Name
          <input #create-display-name type=text name=display_name required>
          <label for=create-role>Role
          <input #create-role type=text name=role list="admin-role-options" value="viewer" required>
          <label for=create-password>Password
          <input #create-password type=password name=password required>
          <button type=submit>Create User
      <section .card>
        <h2>Existing Users
        <datalist #admin-role-options>
          $forall role <- adminRoleOptions
            <option value=#{role}>
        $forall userRow <- users
          <div .version-card>
            <div .section-header>
              <div>
                <strong>#{aurDisplayName userRow}
                <div .meta>#{aurUsername userRow}
              <div>
                <span .badge .#{userStatusBadgeClass userRow}>#{userStatusText userRow}
                <span .badge .latest>#{adminRoleLabel (aurRole userRow)}
            <div .meta>Created: #{aurCreatedAt userRow}
            <div .meta>Last Login: #{fromMaybeText (aurLastLoginAt userRow)}
            <div .version-actions>
              <form .inline-form method=post action=@{AdminUpdateUserRoleR}>
                <input type=hidden name=username value=#{aurUsername userRow}>
                <label>
                  Role
                <input type=text name=role value=#{aurRole userRow} list="admin-role-options" required>
                <button .secondary type=submit>Update Role
              <form .inline-form method=post action=@{AdminResetUserPasswordR}>
                <input type=hidden name=username value=#{aurUsername userRow}>
                <label>
                  New Password
                <input type=password name=password required>
                <button .secondary type=submit>Reset Password
              $if shouldShowUserToggle currentUsername userRow
                <form .inline-form method=post action=@{AdminToggleUserActiveR}>
                  <input type=hidden name=username value=#{aurUsername userRow}>
                  <input type=hidden name=is_active value=#{userToggleIsActiveValue userRow}>
                  <button .#{userToggleButtonClass userRow} type=submit>
                    #{userToggleButtonLabel userRow}
    |]

getAdminActivityR :: Handler Html
getAdminActivityR = do
  requireAdminAuth
  flashMessage <- getMessage
  actorFilter <- runInputGet $ iopt textField "actor"
  actionFilter <- runInputGet $ iopt textField "action"
  targetFilter <- runInputGet $ iopt textField "target"
  entries <- loadAuditEntries (normalize actorFilter) (normalize actionFilter) (normalize targetFilter)
  adminLayout AdminSectionActivity flashMessage
    [whamlet|
      <section .card>
        <h2>Recent Admin Activity
        <form method=get action=@{AdminActivityR} .toolbar>
          <div .field>
            <label for=audit-actor>Actor
            <input #audit-actor type=text name=actor value=#{fromMaybeText actorFilter} placeholder="ops-admin">
          <div .field>
            <label for=audit-action>Action
            <input #audit-action type=text name=action value=#{fromMaybeText actionFilter} placeholder="promote">
          <div .field>
            <label for=audit-target>Target
            <input #audit-target type=text name=target value=#{fromMaybeText targetFilter} placeholder="http-client">
          <div .field>
            <button .secondary type=submit>Filter
      <section .card>
        <h2>Entries
        ^{auditEntriesWidget entries}
    |]

getAdminResolveR :: Handler Html
getAdminResolveR = do
  requireAdminAuth
  app <- getYesod
  flashMessage <- getMessage
  capability <- runInputGet $ iopt textField "capability"
  platform <- runInputGet $ iopt textField "platform"
  channel <- runInputGet $ iopt textField "channel"
  resolved <-
    case (normalize capability, normalize platform) of
      (Just capabilityText, Just platformText) ->
        runDB $ resolvePluginByCapability (appSettings app) capabilityText platformText (normalize channel)
      _ -> pure Nothing
  adminLayout AdminSectionResolve flashMessage
    [whamlet|
      <section .card>
        <h2>Resolve Test
        <div .meta>Run capability resolution exactly as the runner would.
        <form method=get action=@{AdminResolveR}>
          <label for=capability>Capability
          <input #capability type=text name=capability value=#{fromMaybeText capability} placeholder="http.request">
          <label for=query-platform>Platform
          <input #query-platform type=text name=platform value=#{fromMaybeText platform} placeholder="linux-amd64">
          <label for=channel>Channel
          <input #channel type=text name=channel value=#{fromMaybeText channel} placeholder="stable">
          <button .secondary type=submit>Resolve
      <section .card>
        <h2>Resolve Result
        $maybe result <- resolved
          <div .meta>Source: #{rpSource result}
          $maybe artifactUrl <- resolveArtifactUrl (rpManifest result)
            <div .meta>
              Artifact:
              <a href=#{artifactUrl}>#{artifactUrl}
          <div .code>#{decodeJsonText (rpManifest result)}
        $nothing
          <div .meta>Enter a capability and platform to test resolution.
    |]

getAdminAuditR :: Handler Html
getAdminAuditR = redirect AdminActivityR

adminLayout :: AdminSection -> Maybe Html -> WidgetFor App () -> Handler Html
adminLayout section flashMessage content = do
  currentUser <- currentAdminUserEntity
  let actor = adminUserDisplayName . entityVal <$> currentUser
      actorRole = adminRoleLabel . adminUserRoleText . entityVal <$> currentUser
      canManageUsers =
        maybe False
          (roleHasPermission AdminPermissionManageUsers . adminUserRoleText . entityVal)
          currentUser
  defaultLayout $ do
    setTitle "Plugin Catalog Admin"
    toWidget
      [hamlet|
        <style>
          body { font-family: Helvetica, Arial, sans-serif; margin: 0; background: #f4f6f8; color: #16202a; }
          .page { max-width: 1360px; margin: 0 auto; padding: 24px; }
          .shell { display: grid; gap: 24px; }
          .main-stack { display: grid; gap: 20px; }
          .card { background: white; border-radius: 12px; padding: 18px; box-shadow: 0 8px 24px rgba(15, 23, 42, 0.08); }
          .menu-bar { display: flex; gap: 10px; flex-wrap: wrap; justify-content: flex-end; align-items: center; }
          .menu-inline-form { margin: 0; }
          .menu-link { display: inline-block; padding: 10px 12px; border-radius: 10px; background: #f8fafc; color: #0f172a; text-decoration: none; font-weight: 700; border: 1px solid #dbe4ee; white-space: nowrap; }
          .menu-link.active { background: #dcfce7; color: #14532d; border-color: #86efac; }
          .page-title { display: flex; justify-content: space-between; gap: 20px; align-items: start; }
          .page-title-main { min-width: 0; }
          .page-title-side { display: grid; gap: 10px; justify-items: end; }
          .flash { margin-bottom: 16px; padding: 12px 14px; border-radius: 8px; }
          .flash.success { background: #dcfce7; color: #14532d; }
          .flash.error { background: #fee2e2; color: #991b1b; }
          .meta { color: #475569; font-size: 14px; }
          .summary-grid { display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); }
          .summary-card { background: #f8fafc; border: 1px solid #dbe4ee; border-radius: 10px; padding: 12px; }
          .summary-card strong { display: block; font-size: 24px; }
          .toolbar { display: flex; gap: 8px; flex-wrap: wrap; align-items: end; }
          .toolbar .field { flex: 1 1 180px; }
          label { display: block; font-size: 13px; font-weight: 700; margin: 10px 0 4px; }
          input, textarea { width: 100%; box-sizing: border-box; padding: 10px 12px; border: 1px solid #cfd8e3; border-radius: 8px; font-size: 14px; }
          textarea { min-height: 72px; resize: vertical; }
          button { margin-top: 12px; padding: 10px 14px; border: 0; border-radius: 8px; background: #14532d; color: white; font-weight: 700; cursor: pointer; }
          button.secondary { background: #1d4ed8; }
          button.warning { background: #b45309; }
          button.danger { background: #b91c1c; }
          .link-button { display: inline-block; margin-top: 12px; padding: 10px 14px; border-radius: 8px; background: #0f766e; color: white; text-decoration: none; font-weight: 700; }
          .plugin { border-top: 1px solid #e5e7eb; padding-top: 12px; margin-top: 12px; }
          .version-card { margin-top: 10px; padding: 12px; border: 1px solid #e2e8f0; border-radius: 10px; background: #fbfdff; }
          .version-actions { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 8px; }
          .inline-form { display: flex; gap: 8px; align-items: center; margin-top: 8px; flex-wrap: wrap; }
          .inline-form input { max-width: 180px; }
          .badge { display: inline-block; padding: 4px 8px; border-radius: 999px; font-size: 12px; font-weight: 700; background: #e2e8f0; color: #334155; margin-right: 6px; }
          .badge.active { background: #dcfce7; color: #166534; }
          .badge.latest { background: #dbeafe; color: #1d4ed8; }
          .badge.channel { background: #fef3c7; color: #92400e; }
          .code { font-family: Menlo, monospace; font-size: 12px; background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 8px; padding: 12px; overflow: auto; white-space: pre-wrap; word-break: break-word; }
          .audit-row { border-top: 1px solid #e5e7eb; padding-top: 12px; margin-top: 12px; }
          .section-header { display: flex; justify-content: space-between; gap: 12px; align-items: start; }
          .modal-backdrop { position: fixed; inset: 0; background: rgba(15, 23, 42, 0.48); display: none; align-items: center; justify-content: center; padding: 24px; z-index: 30; }
          .modal-backdrop.open { display: flex; }
          .modal-card { width: min(720px, 100%); max-height: 90vh; overflow: auto; background: white; border-radius: 14px; padding: 20px; box-shadow: 0 20px 60px rgba(15, 23, 42, 0.2); }
          .modal-actions { display: flex; gap: 8px; justify-content: flex-end; }
          @media (max-width: 980px) {
            .page-title { flex-direction: column; align-items: stretch; }
            .page-title-side { justify-items: start; }
            .menu-bar { justify-content: flex-start; }
          }
      |]
    toWidget
      [julius|
        document.addEventListener("click", function (event) {
          var openTarget = event.target.closest("[data-modal-open]");
          if (openTarget) {
            var modal = document.getElementById(openTarget.getAttribute("data-modal-open"));
            if (modal) modal.classList.add("open");
          }
          var closeTarget = event.target.closest("[data-modal-close]");
          if (closeTarget) {
            var modalId = closeTarget.getAttribute("data-modal-close");
            var modal = document.getElementById(modalId);
            if (modal) modal.classList.remove("open");
          }
          if (event.target.classList.contains("modal-backdrop")) {
            event.target.classList.remove("open");
          }
        });
      |]
    [whamlet|
      <div .page>
        <div .shell>
          <div .main-stack>
            <div .page-title>
              <div .page-title-main>
                <h1>Plugin Catalog Admin
                <div .meta>
                  Signed in as #{fromMaybeText actor}
                  $maybe roleLabel <- actorRole
                    \ (#{roleLabel})
              <div .page-title-side>
                <div .menu-bar>
                  <a .menu-link .#{menuActive section AdminSectionSummary} href=@{AdminSummaryR}>Summary
                  <a .menu-link .#{menuActive section AdminSectionPlugins} href=@{AdminPluginsR}>Plugins
                  $if canManageUsers
                    <a .menu-link .#{menuActive section AdminSectionUsers} href=@{AdminUsersR}>Users
                  <a .menu-link .#{menuActive section AdminSectionActivity} href=@{AdminActivityR}>Recent Admin Activity
                  <a .menu-link .#{menuActive section AdminSectionResolve} href=@{AdminResolveR}>Resolve Test
                  <form .menu-inline-form method=post action=@{AdminLogoutR}>
                    <button .danger type=submit>Logout
            $maybe message <- flashMessage
              <div .flash .#{flashClass message}>#{flashBody message}
            ^{content}
    |]

menuActive :: AdminSection -> AdminSection -> Text
menuActive current expected
  | current == expected = "active"
  | otherwise = ""

publishModalWidget :: AdminPluginFilters -> Bool -> Maybe Html -> WidgetFor App ()
publishModalWidget filters isOpen modalFlash =
  [whamlet|
    <div #publish-modal .modal-backdrop :isOpen:.open>
      <div .modal-card>
        <div .section-header>
          <div>
            <h2>Publish Plugin
            <div .meta>Upload a bundle and publish a new catalog version.
          <button .secondary type=button data-modal-close="publish-modal">Close
        $maybe message <- modalFlash
          $if isOpen
            <div .flash .#{flashClass message}>#{flashBody message}
        <form method=post action=@{AdminPublishR} enctype="multipart/form-data">
          <input type=hidden name=redirect_plugin value=#{fromMaybeText (apfName filters)}>
          <input type=hidden name=redirect_status value=#{fromMaybeText (apfStatus filters)}>
          <input type=hidden name=redirect_channel value=#{fromMaybeText (apfChannel filters)}>
          <label for=name>Name
          <input #name type=text name=name required>
          <label for=version>Version
          <input #version type=text name=version required>
          <label for=publisher>Publisher
          <input #publisher type=text name=publisher value="aisopsflow" required>
          <label for=runtime>Runtime
          <input #runtime type=text name=runtime value="node" required>
          <label for=platform>Platform
          <input #platform type=text name=platform value="linux-amd64" required>
          <label for=entrypoint>Entrypoint
          <input #entrypoint type=text name=entrypoint value="src/runner-entrypoint.ts" required>
          <label for=capabilities>Capabilities CSV
          <textarea #capabilities name=capabilities placeholder="http.request,news.google.report.word_blocks" required>
          <label for=bundle>Bundle
          <input #bundle type=file name=bundle required>
          <div .modal-actions>
            <button .secondary type=button data-modal-close="publish-modal">Cancel
            <button type=submit>Publish
  |]

pluginCardWidget :: AdminPluginRow -> AdminPluginFilters -> Bool -> WidgetFor App ()
pluginCardWidget plugin filters canManagePlugins =
  [whamlet|
    <div .plugin>
      <h3>#{aprName plugin}
      <div .meta>Publisher: #{aprPublisher plugin}
      <div .meta>Latest: #{fromMaybeText (aprLatestVersion plugin)}
      <div .meta>
        Channels:
        $if null (aprChannels plugin)
          none
        $else
          <ul>
            $forall (channelName, versionText) <- aprChannels plugin
              <li>
                <span .code>#{channelName} -> #{versionText}
      <div .meta>
        Versions:
        <ul>
          $forall versionRow <- aprVersions plugin
            <li .version-card>
              <div>
                <span .code>#{avrVersion versionRow}
                \ /
                #{avrPlatform versionRow}
                \ /
                #{avrRuntime versionRow}
              <div>
                $forall badge <- avrBadges versionRow
                  $if badge == "active"
                    <span .badge.active>active
                  $elseif badge == "latest"
                    <span .badge.latest>latest
                  $else
                    <span .badge.channel>#{badge}
              <div .version-actions>
                <a .link-button href=#{avrDetailHref versionRow}>View Details
                $if canManagePlugins
                  <form method=post action=@{AdminDeactivateVersionR}>
                    <input type=hidden name=plugin_name value=#{aprName plugin}>
                    <input type=hidden name=version value=#{avrVersion versionRow}>
                    <input type=hidden name=platform value=#{avrPlatform versionRow}>
                    <input type=hidden name=redirect_plugin value=#{fromMaybeText (apfName filters)}>
                    <input type=hidden name=redirect_status value=#{fromMaybeText (apfStatus filters)}>
                    <input type=hidden name=redirect_channel value=#{fromMaybeText (apfChannel filters)}>
                    <button .warning type=submit>Deactivate
      $if canManagePlugins
        <form .inline-form method=post action=@{AdminPromoteR}>
          <input type=hidden name=plugin_name value=#{aprName plugin}>
          <input type=hidden name=redirect_plugin value=#{fromMaybeText (apfName filters)}>
          <input type=hidden name=redirect_status value=#{fromMaybeText (apfStatus filters)}>
          <input type=hidden name=redirect_channel value=#{fromMaybeText (apfChannel filters)}>
          <label>
            Version
          <input type=text name=version value=#{fromMaybeText (aprLatestVersion plugin)} required>
          <label>
            Channel
          <input type=text name=channel value="stable" required>
          <button type=submit>Promote
  |]

auditEntriesWidget :: [AdminAuditEntry] -> WidgetFor App ()
auditEntriesWidget entries =
  [whamlet|
    $if null entries
      <div .meta>No audit entries available.
    $else
      $forall entry <- entries
        <div .audit-row>
          <div .meta>#{aaeCreatedAt entry}
          <div>
            <strong>#{fromMaybeText (aaeActor entry)}
            \ #{aaeAction entry}
            \ #{aaeTarget entry}
          $maybe detail <- aaeDetail entry
            <div .code>#{detail}
  |]

paginationWidget :: AdminPluginFilters -> Pagination -> WidgetFor App ()
paginationWidget filters pagination =
  [whamlet|
    $if pgTotalPages pagination > 1
      <div .section-header>
        <div .meta>
          Page #{show (pgPage pagination)} / #{show (pgTotalPages pagination)}
          \ •
          \ Total #{show (pgTotalItems pagination)} plugins
        <div .version-actions>
          $if pgPage pagination > 1
            <a .link-button href=#{pluginsPageHref filters (pgPage pagination - 1)}>Previous
          $if pgPage pagination < pgTotalPages pagination
            <a .link-button href=#{pluginsPageHref filters (pgPage pagination + 1)}>Next
  |]

postAdminPublishR :: Handler Html
postAdminPublishR = do
  requireAdminPermission AdminPermissionManagePlugins
  filters <- pluginFiltersFromPost
  outcome <- publishPluginFromBodySafe False
  case outcome of
    Left err -> do
      setMessage (toHtml ("ERROR: " <> err))
      redirect (AdminPluginsR, pluginFilterQueryPairs filters <> [("open_publish", "1")])
    Right result -> do
      logAdminAction "publish" (pbrName result <> "@" <> pbrVersion result) (Just ("sha256=" <> pbrSha256 result))
      pluginEntity <- runDB $ getBy404 (UniquePluginName (pbrName result))
      let pluginId = entityKey pluginEntity
      versionEntity <-
        runDB $
          selectFirst
            [ PluginVersionPluginId ==. pluginId
            , PluginVersionVersion ==. pbrVersion result
            ]
            [Asc PluginVersionPlatform]
      case versionEntity of
        Just (Entity _ row) -> do
          setMessage $
            toHtml $
              "Published "
                <> pbrName result
                <> "@"
                <> pbrVersion result
                <> " on "
                <> pluginVersionPlatform row
          redirect (AdminPluginsR, pluginFilterQueryPairs filters)
        Nothing -> redirect (AdminPluginsR, pluginFilterQueryPairs filters)

postAdminPromoteR :: Handler Html
postAdminPromoteR = do
  requireAdminPermission AdminPermissionManagePlugins
  filters <- pluginFiltersFromPost
  pluginName <- runInputPost $ ireq textField "plugin_name"
  version <- runInputPost $ ireq textField "version"
  channel <- runInputPost $ ireq textField "channel"
  Entity pluginId _ <- runDB $ getBy404 (UniquePluginName pluginName)
  existingVersion <-
    runDB $
      selectFirst
        [ PluginVersionPluginId ==. pluginId
        , PluginVersionVersion ==. version
        ]
        []
  case existingVersion of
    Nothing -> invalidArgs ["unknown plugin version"]
    Just _ -> do
      runDB $ promotePluginChannel pluginId version channel
      logAdminAction "promote" (pluginName <> "@" <> version) (Just ("channel=" <> channel))
      setMessage $ toHtml ("Promoted " <> pluginName <> "@" <> version <> " to " <> channel)
      redirect (AdminPluginsR, pluginFilterQueryPairs filters)

getAdminVersionDetailR :: Text -> Text -> Text -> Handler Html
getAdminVersionDetailR pluginName version platform = do
  requireAdminAuth
  flashMessage <- getMessage
  filters <- pluginFiltersFromRequest
  app <- getYesod
  canManagePlugins <- hasAdminPermission AdminPermissionManagePlugins
  Entity pluginId pluginRow <- runDB $ getBy404 (UniquePluginName pluginName)
  versionEntity <-
    runDB $
      selectFirst
        [ PluginVersionPluginId ==. pluginId
        , PluginVersionVersion ==. version
        , PluginVersionPlatform ==. platform
        ]
        []
  Entity versionId versionRow <-
    case versionEntity of
      Nothing -> notFound
      Just entity -> pure entity
  caps <- runDB $ selectList [PluginCapabilityPluginVersionId ==. versionId] [Asc PluginCapabilityCapability]
  let artifactUrl = makeAbsoluteUrl (appSettings app) ("/artifacts/" <> pluginName <> "/" <> version <> "/bundle")
      runtimeManifestUrl = "/api/plugins/" <> pluginName <> "/" <> version <> "/manifest"
      catalogManifestUrl = "/api/plugins/" <> pluginName <> "/" <> version <> "/catalog-manifest"
  adminLayout AdminSectionPlugins flashMessage
    [whamlet|
      <section .card>
        <a .link-button href=#{appendPluginFilterQuery filters "/admin/plugins"}>Back To Plugins
        <h2>#{pluginName} @ #{version}
        <div .summary-grid>
          <div .summary-card>
            <div .meta>Publisher
            <strong>#{pluginPublisher pluginRow}
          <div .summary-card>
            <div .meta>Platform
            <strong>#{pluginVersionPlatform versionRow}
          <div .summary-card>
            <div .meta>Runtime
            <strong>#{pluginVersionRuntime versionRow}
      <section .card>
        <h2>Version Detail
        <div .meta>Status: #{pluginVersionStatus versionRow}
        <div .meta>Entrypoint: #{pluginVersionEntrypoint versionRow}
        <div .meta>Artifact Path: #{pluginVersionArtifactPath versionRow}
        <div .meta>SHA256: #{pluginVersionSha256 versionRow}
        <div .meta>
          Artifact URL:
          <a href=#{artifactUrl}>
            #{artifactUrl}
        <div .meta>
          Runtime Manifest API:
          <a href=#{runtimeManifestUrl}>
            #{runtimeManifestUrl}
        <div .meta>
          Catalog Manifest API:
          <a href=#{catalogManifestUrl}>
            #{catalogManifestUrl}
        <div .meta>Capabilities:
        <ul>
          $forall Entity _ cap <- caps
            <li>
              <span .code>#{pluginCapabilityCapability cap}
      <section .card>
        <h2>Runtime Manifest
        <div .code>#{pluginVersionManifestJson versionRow}
      <section .card>
        <h2>Catalog Manifest
        <div .code>#{pluginVersionCatalogManifestJson versionRow}
      $if canManagePlugins
        <section .card>
          <h2>Danger Zone
          <div .meta>Deleting changes the version status to deleted and clears any matching channel pointers.
          <form method=post action=@{AdminDeleteVersionR}>
            <input type=hidden name=plugin_name value=#{pluginName}>
            <input type=hidden name=version value=#{version}>
            <input type=hidden name=platform value=#{platform}>
            <input type=hidden name=redirect_plugin value=#{fromMaybeText (apfName filters)}>
            <input type=hidden name=redirect_status value=#{fromMaybeText (apfStatus filters)}>
            <input type=hidden name=redirect_channel value=#{fromMaybeText (apfChannel filters)}>
            <button .danger type=submit>Confirm Delete
    |]

postAdminDeactivateVersionR :: Handler Html
postAdminDeactivateVersionR = do
  requireAdminPermission AdminPermissionManagePlugins
  filters <- pluginFiltersFromPost
  pluginName <- runInputPost $ ireq textField "plugin_name"
  version <- runInputPost $ ireq textField "version"
  platform <- runInputPost $ ireq textField "platform"
  Entity pluginId _ <- runDB $ getBy404 (UniquePluginName pluginName)
  versionEntity <-
    runDB $
      selectFirst
        [ PluginVersionPluginId ==. pluginId
        , PluginVersionVersion ==. version
        , PluginVersionPlatform ==. platform
        ]
        []
  case versionEntity of
    Nothing -> invalidArgs ["unknown plugin version"]
    Just (Entity versionId _) -> do
      runDB $ update versionId [PluginVersionStatus =. "inactive"]
      refreshPluginPointers pluginId version
      logAdminAction "deactivate" (pluginName <> "@" <> version) (Just ("platform=" <> platform))
      setMessage $ toHtml ("Deactivated " <> pluginName <> "@" <> version <> " on " <> platform)
      redirect (AdminPluginsR, pluginFilterQueryPairs filters)

postAdminDeleteVersionR :: Handler Html
postAdminDeleteVersionR = do
  requireAdminPermission AdminPermissionManagePlugins
  filters <- pluginFiltersFromPost
  pluginName <- runInputPost $ ireq textField "plugin_name"
  version <- runInputPost $ ireq textField "version"
  platform <- runInputPost $ ireq textField "platform"
  Entity pluginId _ <- runDB $ getBy404 (UniquePluginName pluginName)
  versionEntity <-
    runDB $
      selectFirst
        [ PluginVersionPluginId ==. pluginId
        , PluginVersionVersion ==. version
        , PluginVersionPlatform ==. platform
        ]
        []
  case versionEntity of
    Nothing -> invalidArgs ["unknown plugin version"]
    Just (Entity versionId _) -> do
      runDB $ update versionId [PluginVersionStatus =. "deleted"]
      refreshPluginPointers pluginId version
      logAdminAction "delete" (pluginName <> "@" <> version) (Just ("platform=" <> platform))
      setMessage $ toHtml ("Marked deleted " <> pluginName <> "@" <> version <> " on " <> platform)
      redirect (AdminPluginsR, pluginFilterQueryPairs filters)

postAdminCreateUserR :: Handler Html
postAdminCreateUserR = do
  requireAdminPermission AdminPermissionManageUsers
  username <- runInputPost $ ireq textField "username"
  displayName <- runInputPost $ ireq textField "display_name"
  role <- runInputPost $ ireq textField "role"
  password <- runInputPost $ ireq textField "password"
  let normalizedUsername = T.toLower (T.strip username)
      normalizedDisplayName = T.strip displayName
      normalizedRole = normalizeAdminRole role
  existing <- runDB $ getBy (UniqueAdminUsername normalizedUsername)
  case existing of
    Just _ -> do
      setMessage (toHtml ("ERROR: Username already exists." :: Text))
      redirect AdminUsersR
    Nothing
      | T.null normalizedUsername || T.null normalizedDisplayName || T.null (T.strip password) -> do
          setMessage (toHtml ("ERROR: Username, display name, role, and password are required." :: Text))
          redirect AdminUsersR
      | not (isKnownAdminRole normalizedRole) -> do
          setMessage (toHtml ("ERROR: Unknown role." :: Text))
          redirect AdminUsersR
      | otherwise -> do
          now <- liftIO getCurrentTime
          passwordHash <- liftIO (hashPassword password)
          _ <-
            runDB $
              insert
                AdminUser
                  { adminUserUsername = normalizedUsername
                  , adminUserDisplayName = normalizedDisplayName
                  , adminUserRole = Just normalizedRole
                  , adminUserPasswordHash = passwordHash
                  , adminUserIsActive = True
                  , adminUserCreatedAt = now
                  , adminUserUpdatedAt = now
                  , adminUserLastLoginAt = Nothing
                  }
          logAdminAction "create-user" normalizedUsername (Just ("role=" <> normalizedRole))
          setMessage $ toHtml ("Created user " <> normalizedUsername)
          redirect AdminUsersR

postAdminToggleUserActiveR :: Handler Html
postAdminToggleUserActiveR = do
  requireAdminPermission AdminPermissionManageUsers
  username <- runInputPost $ ireq textField "username"
  isActiveInput <- runInputPost $ ireq textField "is_active"
  currentUser <- requireCurrentAdminUserEntity
  let normalizedUsername = T.toLower (T.strip username)
      shouldActivate = T.toLower (T.strip isActiveInput) == "true"
  targetEntity <- runDB $ getBy404 (UniqueAdminUsername normalizedUsername)
  now <- liftIO getCurrentTime
  canToggle <- canChangeUserActivation currentUser targetEntity shouldActivate
  if not canToggle
    then do
      setMessage (toHtml ("ERROR: At least one active owner must remain." :: Text))
      redirect AdminUsersR
    else do
      runDB $
        update
          (entityKey targetEntity)
          [ AdminUserIsActive =. shouldActivate
          , AdminUserUpdatedAt =. now
          ]
      logAdminAction
        (if shouldActivate then "activate-user" else "deactivate-user")
        normalizedUsername
        Nothing
      setMessage $
        toHtml $
          (if shouldActivate then "Activated " else "Deactivated ")
            <> normalizedUsername
      redirect AdminUsersR

postAdminResetUserPasswordR :: Handler Html
postAdminResetUserPasswordR = do
  requireAdminPermission AdminPermissionManageUsers
  username <- runInputPost $ ireq textField "username"
  password <- runInputPost $ ireq textField "password"
  let normalizedUsername = T.toLower (T.strip username)
  if T.null (T.strip password)
    then do
      setMessage (toHtml ("ERROR: Password is required." :: Text))
      redirect AdminUsersR
    else do
      Entity userId _ <- runDB $ getBy404 (UniqueAdminUsername normalizedUsername)
      now <- liftIO getCurrentTime
      passwordHash <- liftIO (hashPassword password)
      runDB $
        update
          userId
          [ AdminUserPasswordHash =. passwordHash
          , AdminUserUpdatedAt =. now
          ]
      logAdminAction "reset-password" normalizedUsername Nothing
      setMessage $ toHtml ("Updated password for " <> normalizedUsername)
      redirect AdminUsersR

postAdminUpdateUserRoleR :: Handler Html
postAdminUpdateUserRoleR = do
  requireAdminPermission AdminPermissionManageUsers
  username <- runInputPost $ ireq textField "username"
  role <- runInputPost $ ireq textField "role"
  currentUser <- requireCurrentAdminUserEntity
  let normalizedUsername = T.toLower (T.strip username)
      normalizedRole = normalizeAdminRole role
  if not (isKnownAdminRole normalizedRole)
    then do
      setMessage (toHtml ("ERROR: Unknown role." :: Text))
      redirect AdminUsersR
    else do
      targetEntity <- runDB $ getBy404 (UniqueAdminUsername normalizedUsername)
      now <- liftIO getCurrentTime
      canChange <- canChangeUserRole currentUser targetEntity normalizedRole
      if not canChange
        then do
          setMessage (toHtml ("ERROR: At least one active owner must remain." :: Text))
          redirect AdminUsersR
        else do
          runDB $
            update
              (entityKey targetEntity)
              [ AdminUserRole =. Just normalizedRole
              , AdminUserUpdatedAt =. now
              ]
          logAdminAction "update-role" normalizedUsername (Just ("role=" <> normalizedRole))
          setMessage $ toHtml ("Updated role for " <> normalizedUsername)
          redirect AdminUsersR

loadAdminPlugins :: Handler [AdminPluginRow]
loadAdminPlugins = do
  plugins <- runDB $ selectList [] [Asc PluginName]
  mapM loadPlugin plugins
  where
    loadPlugin :: Entity Plugin -> Handler AdminPluginRow
    loadPlugin (Entity pluginId pluginRow) = do
      versions <- runDB $ selectList [PluginVersionPluginId ==. pluginId] [Desc PluginVersionCreatedAt]
      channels <- runDB $ selectList [PluginChannelPluginId ==. pluginId] [Asc PluginChannelChannel]
      pure
        AdminPluginRow
          { aprName = pluginName pluginRow
          , aprPublisher = pluginPublisher pluginRow
          , aprLatestVersion = pluginLatestVersion pluginRow
          , aprChannels =
              [ (pluginChannelChannel row, pluginChannelVersion row)
              | Entity _ row <- channels
              ]
          , aprVersions =
              [ AdminVersionRow
                  { avrVersion = pluginVersionVersion row
                  , avrPlatform = pluginVersionPlatform row
                  , avrRuntime = pluginVersionRuntime row
                  , avrStatus = pluginVersionStatus row
                  , avrBadges = versionBadges pluginRow channels row
                  , avrDetailHref =
                      adminVersionDetailHref
                        (pluginName pluginRow)
                        (pluginVersionVersion row)
                        (pluginVersionPlatform row)
                  }
              | Entity _ row <- versions
              ]
          }

    versionBadges pluginRow channelEntities row =
      let latestBadge =
            [ "latest"
            | pluginLatestVersion pluginRow == Just (pluginVersionVersion row)
            ]
          statusBadge = [pluginVersionStatus row]
          channelBadges =
            [ pluginChannelChannel channelRow
            | Entity _ channelRow <- channelEntities
            , pluginChannelVersion channelRow == pluginVersionVersion row
            ]
       in nub (statusBadge <> latestBadge <> channelBadges)

loadRecentAuditEntries :: Handler [AdminAuditEntry]
loadRecentAuditEntries = do
  rows <- runDB $ selectList [] [Desc AdminAuditLogCreatedAt, LimitTo 10]
  pure (map toAdminAuditEntry rows)

loadAdminUsers :: Handler [AdminUserRow]
loadAdminUsers = do
  rows <- runDB $ selectList [] [Asc AdminUserUsername]
  pure (map toAdminUserRow rows)

toAdminUserRow :: Entity AdminUser -> AdminUserRow
toAdminUserRow (Entity _ row) =
  AdminUserRow
    { aurUsername = adminUserUsername row
    , aurDisplayName = adminUserDisplayName row
    , aurRole = adminUserRoleText row
    , aurIsActive = adminUserIsActive row
    , aurLastLoginAt = formatUtcText <$> adminUserLastLoginAt row
    , aurCreatedAt = formatUtcText (adminUserCreatedAt row)
    }

userStatusBadgeClass :: AdminUserRow -> Text
userStatusBadgeClass row
  | aurIsActive row = "active"
  | otherwise = "channel"

userStatusText :: AdminUserRow -> Text
userStatusText row
  | aurIsActive row = "active"
  | otherwise = "inactive"

shouldShowUserToggle :: Text -> AdminUserRow -> Bool
shouldShowUserToggle currentUsername row =
  aurUsername row /= currentUsername || not (aurIsActive row)

userToggleIsActiveValue :: AdminUserRow -> Text
userToggleIsActiveValue row
  | aurIsActive row = "false"
  | otherwise = "true"

userToggleButtonClass :: AdminUserRow -> Text
userToggleButtonClass row
  | aurIsActive row = "warning"
  | otherwise = "secondary"

userToggleButtonLabel :: AdminUserRow -> Text
userToggleButtonLabel row
  | aurIsActive row = "Deactivate"
  | otherwise = "Activate"

attachPluginFilters :: AdminPluginFilters -> [AdminPluginRow] -> [AdminPluginRow]
attachPluginFilters filters =
  map
    (\pluginRow ->
      pluginRow
        { aprVersions =
            map
              (\versionRow ->
                versionRow
                  { avrDetailHref =
                      appendPluginFilterQuery filters (avrDetailHref versionRow)
                  }
              )
              (aprVersions pluginRow)
        }
    )

loadAuditEntries :: Maybe Text -> Maybe Text -> Maybe Text -> Handler [AdminAuditEntry]
loadAuditEntries actorFilter actionFilter targetFilter = do
  rows <- runDB $ selectList [] [Desc AdminAuditLogCreatedAt, LimitTo 200]
  pure
    [ entry
    | entry <- map toAdminAuditEntry rows
    , auditEntryMatches actorFilter actionFilter targetFilter entry
    ]

toAdminAuditEntry :: Entity AdminAuditLog -> AdminAuditEntry
toAdminAuditEntry (Entity _ row) =
  AdminAuditEntry
    { aaeAction = adminAuditLogAction row
    , aaeActor = adminAuditLogActor row
    , aaeTarget = adminAuditLogTarget row
    , aaeDetail = adminAuditLogDetail row
    , aaeCreatedAt = T.pack (formatTime defaultTimeLocale "%F %T UTC" (adminAuditLogCreatedAt row))
    }

auditEntryMatches :: Maybe Text -> Maybe Text -> Maybe Text -> AdminAuditEntry -> Bool
auditEntryMatches actorFilter actionFilter targetFilter entry =
  matchesMaybe actorFilter (fromMaybeText (aaeActor entry))
    && matchesMaybe actionFilter (aaeAction entry)
    && matchesMaybe targetFilter (aaeTarget entry)

matchesMaybe :: Maybe Text -> Text -> Bool
matchesMaybe Nothing _ = True
matchesMaybe (Just needle) haystack =
  T.toLower needle `T.isInfixOf` T.toLower haystack

applyPluginFilters :: Maybe Text -> Maybe Text -> Maybe Text -> [AdminPluginRow] -> [AdminPluginRow]
applyPluginFilters nameFilter statusFilter channelFilter =
  filter matchesName . filter hasVersions . map trimVersions
  where
    matchesName row =
      case nameFilter of
        Nothing -> True
        Just needle -> T.toLower needle `T.isInfixOf` T.toLower (aprName row)
    trimVersions row =
      let keptVersions =
            case statusFilter of
              Nothing -> aprVersions row
              Just wanted ->
                filter (\versionRow -> T.toLower (avrStatus versionRow) == T.toLower wanted) (aprVersions row)
          channelTrimmed =
            case channelFilter of
              Nothing -> keptVersions
              Just wanted ->
                filter
                  (\versionRow -> any (\badge -> T.toLower badge == T.toLower wanted) (avrBadges versionRow))
                  keptVersions
       in row {aprVersions = channelTrimmed}
    hasVersions row = not (null (aprVersions row))

listKnownChannels :: [AdminPluginRow] -> [Text]
listKnownChannels rows =
  nub
    [ channelName
    | row <- rows
    , (channelName, _) <- aprChannels row
    ]

adminRoleOptions :: [Text]
adminRoleOptions = ["owner", "admin", "publisher", "viewer"]

normalizeAdminRole :: Text -> Text
normalizeAdminRole =
  T.toLower . T.strip

isKnownAdminRole :: Text -> Bool
isKnownAdminRole role =
  normalizeAdminRole role `elem` adminRoleOptions

adminUserRoleText :: AdminUser -> Text
adminUserRoleText user =
  fromMaybe "admin" (normalizeAdminRole <$> adminUserRole user)

adminRoleLabel :: Text -> Text
adminRoleLabel role =
  case normalizeAdminRole role of
    "owner" -> "Owner"
    "admin" -> "Admin"
    "publisher" -> "Publisher"
    "viewer" -> "Viewer"
    other -> other

roleHasPermission :: AdminPermission -> Text -> Bool
roleHasPermission permission role =
  case (permission, normalizeAdminRole role) of
    (AdminPermissionManageUsers, "owner") -> True
    (AdminPermissionManageUsers, "admin") -> True
    (AdminPermissionManagePlugins, "owner") -> True
    (AdminPermissionManagePlugins, "admin") -> True
    (AdminPermissionManagePlugins, "publisher") -> True
    _ -> False

hasAdminPermission :: AdminPermission -> Handler Bool
hasAdminPermission permission = do
  currentUser <- currentAdminUserEntity
  pure $
    maybe False
      (roleHasPermission permission . adminUserRoleText . entityVal)
      currentUser

requireAdminPermission :: AdminPermission -> Handler ()
requireAdminPermission permission = do
  requireAdminAuth
  permitted <- hasAdminPermission permission
  if permitted
    then pure ()
    else permissionDenied ("insufficient admin permissions" :: Text)

requireCurrentAdminUserEntity :: Handler (Entity AdminUser)
requireCurrentAdminUserEntity = do
  maybeUser <- currentAdminUserEntity
  case maybeUser of
    Just user -> pure user
    Nothing -> redirect AdminLoginR

formatUtcText :: UTCTime -> Text
formatUtcText =
  T.pack . formatTime defaultTimeLocale "%F %T UTC"

canChangeUserActivation :: Entity AdminUser -> Entity AdminUser -> Bool -> Handler Bool
canChangeUserActivation currentUser targetUser shouldActivate
  | shouldActivate = pure True
  | adminUserUsername (entityVal currentUser) == adminUserUsername (entityVal targetUser) = do
      owners <- activeOwnerCount
      pure (adminUserRoleText (entityVal targetUser) /= "owner" || owners > 1)
  | adminUserRoleText (entityVal targetUser) /= "owner" = pure True
  | otherwise = do
      owners <- activeOwnerCount
      pure (owners > 1)

canChangeUserRole :: Entity AdminUser -> Entity AdminUser -> Text -> Handler Bool
canChangeUserRole currentUser targetUser nextRole
  | currentRole /= "owner" = pure True
  | normalizeAdminRole nextRole == "owner" = pure True
  | adminUserUsername (entityVal currentUser) == adminUserUsername (entityVal targetUser) = do
      owners <- activeOwnerCount
      pure (owners > 1)
  | otherwise = do
      owners <- activeOwnerCount
      pure (owners > 1)
  where
    currentRole = adminUserRoleText (entityVal targetUser)

activeOwnerCount :: Handler Int
activeOwnerCount =
  runDB $ count [AdminUserIsActive ==. True, AdminUserRole ==. Just "owner"]

normalize :: Maybe Text -> Maybe Text
normalize = fmap T.strip >=> \value -> if T.null value then Nothing else Just value

fromMaybeText :: Maybe Text -> Text
fromMaybeText = maybe "" id

adminDashboardHref :: Text
adminDashboardHref = "/admin/summary"

adminVersionDetailHref :: Text -> Text -> Text -> Text
adminVersionDetailHref pluginName version platform =
  "/admin/version/"
    <> pluginName
    <> "/"
    <> version
    <> "/"
    <> platform

appendPluginFilterQuery :: AdminPluginFilters -> Text -> Text
appendPluginFilterQuery filters basePath =
  case pluginFilterQueryPairs filters of
    [] -> basePath
    pairs ->
      basePath
        <> "?"
        <> T.intercalate "&" [key <> "=" <> value | (key, value) <- pairs]

pluginFilterQueryPairs :: AdminPluginFilters -> [(Text, Text)]
pluginFilterQueryPairs filters =
  [ (key, value)
  | (key, maybeValue) <-
      [ ("plugin", normalize (apfName filters))
      , ("status", normalize (apfStatus filters))
      , ("filter_channel", normalize (apfChannel filters))
      ]
  , Just value <- [maybeValue]
  ]

pluginsPageHref :: AdminPluginFilters -> Int -> Text
pluginsPageHref filters pageNumber =
  let pairs = pluginFilterQueryPairs filters <> [("page", T.pack (show pageNumber))]
   in "/admin/plugins?" <> T.intercalate "&" [key <> "=" <> value | (key, value) <- pairs]

pluginFiltersFromRequest :: Handler AdminPluginFilters
pluginFiltersFromRequest =
  AdminPluginFilters
    <$> runInputGet (iopt textField "plugin")
    <*> runInputGet (iopt textField "status")
    <*> runInputGet (iopt textField "filter_channel")

pluginFiltersFromPost :: Handler AdminPluginFilters
pluginFiltersFromPost =
  AdminPluginFilters
    <$> runInputPost (iopt textField "redirect_plugin")
    <*> runInputPost (iopt textField "redirect_status")
    <*> runInputPost (iopt textField "redirect_channel")

paginate :: Int -> Maybe Int -> [a] -> Pagination
paginate pageSize requestedPage items =
  let totalItems = length items
      totalPages = max 1 ((totalItems + pageSize - 1) `div` pageSize)
      rawPage = maybe 1 id requestedPage
      currentPage = min totalPages (max 1 rawPage)
   in Pagination
        { pgPage = currentPage
        , pgPageSize = pageSize
        , pgTotalItems = totalItems
        , pgTotalPages = totalPages
        }

pageItems :: Pagination -> [a] -> [a]
pageItems pagination =
  take (pgPageSize pagination)
    . drop ((pgPage pagination - 1) * pgPageSize pagination)

buildSummary :: [AdminPluginRow] -> AdminSummary
buildSummary rows =
  AdminSummary
    { asPluginCount = length rows
    , asActiveVersionCount =
        length
          [ ()
          | row <- rows
          , versionRow <- aprVersions row
          , avrStatus versionRow == "active"
          ]
    , asChannelCount = length (listKnownChannels rows)
    }

resolveArtifactUrl :: Value -> Maybe Text
resolveArtifactUrl (Aeson.Object obj) =
  case parseMaybe (.: "artifact") obj of
    Just (Aeson.Object artifactObj) -> parseMaybe (.: "url") artifactObj
    _ -> Nothing
resolveArtifactUrl _ = Nothing

decodeJsonText :: Value -> Text
decodeJsonText = LT.toStrict . TL.decodeUtf8 . Aeson.encode

flashClass :: Html -> Text
flashClass message
  | "ERROR:" `T.isPrefixOf` body = "error"
  | otherwise = "success"
  where
    body = flashBody message

flashBody :: Html -> Text
flashBody message =
  case T.strip (renderHtmlText message) of
    stripped
      | "ERROR:" `T.isPrefixOf` stripped -> T.strip (T.drop 6 stripped)
      | "SUCCESS:" `T.isPrefixOf` stripped -> T.strip (T.drop 8 stripped)
      | otherwise -> stripped

renderHtmlText :: Html -> Text
renderHtmlText = LT.toStrict . renderHtml

refreshPluginPointers :: PluginId -> Text -> Handler ()
refreshPluginPointers pluginId changedVersion = do
  runDB $
    deleteWhere
      [ PluginChannelPluginId ==. pluginId
      , PluginChannelVersion ==. changedVersion
      ]
  nextActive <-
    runDB $
      selectFirst
        [ PluginVersionPluginId ==. pluginId
        , PluginVersionStatus ==. "active"
        ]
        [Desc PluginVersionCreatedAt]
  runDB $
    update
      pluginId
      [ PluginLatestVersion =. fmap (pluginVersionVersion . entityVal) nextActive
      ]

logAdminAction :: Text -> Text -> Maybe Text -> Handler ()
logAdminAction action target detail = do
  actor <- currentAdminActor
  requestDetail <- currentRequestAuditDetail
  logAdminActionWithActor actor action target (mergeAuditDetail detail requestDetail)

logAdminActionWithActor :: Maybe Text -> Text -> Text -> Maybe Text -> Handler ()
logAdminActionWithActor actor action target detail = do
  now <- liftIO getCurrentTime
  runDB $
    insert_
      AdminAuditLog
        { adminAuditLogAction = action
        , adminAuditLogActor = normalize actor
        , adminAuditLogTarget = target
        , adminAuditLogDetail = detail
        , adminAuditLogCreatedAt = now
        }

requireAdminAuth :: Handler ()
requireAdminAuth = do
  hasSession <- hasValidAdminSession
  if hasSession
    then pure ()
    else redirect AdminLoginR

hasValidAdminSession :: Handler Bool
hasValidAdminSession = do
  now <- liftIO getCurrentTime
  maybeSession <- currentAdminSessionEntity
  case maybeSession of
    Just (Entity _ sessionRow) | adminSessionExpiresAt sessionRow > now -> pure True
    Just (Entity sessionId _) -> do
      runDB $ delete sessionId
      pure False
    Nothing -> pure False

currentAdminActor :: Handler (Maybe Text)
currentAdminActor = fmap (adminUserDisplayName . entityVal) <$> currentAdminUserEntity

currentAdminUserEntity :: Handler (Maybe (Entity AdminUser))
currentAdminUserEntity = do
  now <- liftIO getCurrentTime
  maybeSession <- currentAdminSessionEntity
  case maybeSession of
    Just (Entity sessionId sessionRow)
      | adminSessionExpiresAt sessionRow > now -> do
          user <- runDB $ getEntity (adminSessionAdminUserId sessionRow)
          case user of
            Just entity | adminUserIsActive (entityVal entity) -> pure (Just entity)
            _ -> do
              runDB $ delete sessionId
              pure Nothing
      | otherwise -> do
          runDB $ delete sessionId
          pure Nothing
    Nothing -> pure Nothing

currentAdminSessionEntity :: Handler (Maybe (Entity AdminSession))
currentAdminSessionEntity = do
  cookieValue <- lookupCookie adminSessionCookieText
  case normalize cookieValue of
    Nothing -> pure Nothing
    Just sessionToken ->
      runDB $ getBy (UniqueAdminSessionToken sessionToken)

adminSessionCookieText :: Text
adminSessionCookieText = "plugin_catalog_session"

adminSessionCookieName :: ByteString
adminSessionCookieName = "plugin_catalog_session"

currentRequestAuditDetail :: Handler (Maybe Text)
currentRequestAuditDetail = do
  req <- waiRequest
  forwardedFor <- lookupHeader "X-Forwarded-For"
  userAgent <- lookupHeader hUserAgent
  let remoteIp =
        case normalize (TE.decodeUtf8 <$> forwardedFor) of
          Just forwarded -> Just forwarded
          Nothing -> Just (T.pack (show (remoteHost req)))
      userAgentText = normalize (TE.decodeUtf8 <$> userAgent)
      parts =
        concat
          [ maybe [] (\ip -> ["ip=" <> ip]) remoteIp
          , maybe [] (\ua -> ["ua=" <> ua]) userAgentText
          ]
  pure $
    case parts of
      [] -> Nothing
      _ -> Just (T.intercalate ", " parts)

mergeAuditDetail :: Maybe Text -> Maybe Text -> Maybe Text
mergeAuditDetail left right =
  case (normalize left, normalize right) of
    (Nothing, Nothing) -> Nothing
    (Just l, Nothing) -> Just l
    (Nothing, Just r) -> Just r
    (Just l, Just r) -> Just (l <> "; " <> r)
