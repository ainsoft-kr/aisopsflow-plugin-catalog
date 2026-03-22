{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module PluginCatalogServer.Model where

import Data.Text (Text)
import Data.Time (UTCTime)
import Database.Persist.TH

share
  [mkPersist sqlSettings, mkMigrate "migrateAll"]
  [persistLowerCase|
AdminUser
    username Text
    displayName Text
    role Text Maybe
    passwordHash Text
    isActive Bool
    createdAt UTCTime
    updatedAt UTCTime
    lastLoginAt UTCTime Maybe
    UniqueAdminUsername username
    deriving Show
AdminSession
    adminUserId AdminUserId
    sessionToken Text
    createdAt UTCTime
    expiresAt UTCTime
    UniqueAdminSessionToken sessionToken
    deriving Show
Plugin
    name Text
    publisher Text
    latestVersion Text Maybe
    UniquePluginName name
    deriving Show
PluginVersion
    pluginId PluginId
    version Text
    runtime Text
    platform Text
    entrypoint Text
    artifactPath Text
    sha256 Text
    sizeBytes Int
    manifestJson Text
    catalogManifestJson Text
    status Text
    createdAt UTCTime
    UniquePluginVersion pluginId version platform
    deriving Show
PluginCapability
    pluginVersionId PluginVersionId
    capability Text
    UniquePluginCapability pluginVersionId capability
    deriving Show
PluginChannel
    pluginId PluginId
    channel Text
    version Text
    UniquePluginChannel pluginId channel
    deriving Show
AdminAuditLog
    action Text
    actor Text Maybe
    target Text
    detail Text Maybe
    createdAt UTCTime
    deriving Show
|]
