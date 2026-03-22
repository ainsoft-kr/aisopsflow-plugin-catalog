{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module PluginCatalogServer.Domain.Manifest
  ( ArtifactRef(..)
  , SandboxConfig(..)
  , PluginManifestV2(..)
  , CatalogManifestV1(..)
  , renderManifestValue
  , renderCatalogManifestValue
  ) where

import Data.Aeson (ToJSON(..), Value, object, (.=))
import Data.Text (Text)
import GHC.Generics (Generic)

data ArtifactRef = ArtifactRef
  { arUrl :: Text
  , arSha256 :: Text
  , arSizeBytes :: Int
  }
  deriving (Eq, Generic, Show)

data SandboxConfig = SandboxConfig
  { scTimeoutSeconds :: Maybe Int
  }
  deriving (Eq, Generic, Show)

data PluginManifestV2 = PluginManifestV2
  { pmName :: Text
  , pmPublisher :: Text
  , pmVersion :: Text
  , pmRuntime :: Text
  , pmPlatform :: Text
  , pmEntrypoint :: Text
  , pmArtifact :: ArtifactRef
  , pmCapabilities :: [Text]
  , pmSandbox :: SandboxConfig
  }
  deriving (Eq, Generic, Show)

data CatalogManifestV1 = CatalogManifestV1
  { cmName :: Text
  , cmPublisher :: Text
  , cmVersion :: Text
  , cmPluginRef :: Text
  , cmManifestPath :: Text
  , cmCapabilities :: [Text]
  }
  deriving (Eq, Generic, Show)

instance ToJSON ArtifactRef where
  toJSON artifact =
    object
      [ "url" .= arUrl artifact
      , "sha256" .= arSha256 artifact
      , "size_bytes" .= arSizeBytes artifact
      ]

instance ToJSON SandboxConfig where
  toJSON sandbox =
    object
      [ "timeout_seconds" .= scTimeoutSeconds sandbox
      ]

renderManifestValue :: PluginManifestV2 -> Value
renderManifestValue manifest =
  object
    [ "api_version" .= ("v2" :: Text)
    , "name" .= pmName manifest
    , "publisher" .= pmPublisher manifest
    , "plugin_version" .= pmVersion manifest
    , "runtime" .= pmRuntime manifest
    , "platform" .= pmPlatform manifest
    , "entrypoint" .= pmEntrypoint manifest
    , "artifact" .= pmArtifact manifest
    , "compatibility" .= object
        [ "min_core" .= ("0.1.0" :: Text)
        , "min_runner" .= ("0.1.0" :: Text)
        , "runner_plugin_api" .= ("v1" :: Text)
        ]
    , "capabilities" .= pmCapabilities manifest
    , "sandbox" .= pmSandbox manifest
    ]

renderCatalogManifestValue :: CatalogManifestV1 -> Value
renderCatalogManifestValue manifest =
  object
    [ "api_version" .= ("v1" :: Text)
    , "name" .= cmName manifest
    , "publisher" .= cmPublisher manifest
    , "plugin_version" .= cmVersion manifest
    , "plugin_ref" .= cmPluginRef manifest
    , "manifest_path" .= cmManifestPath manifest
    , "compatibility" .= object
        [ "min_core" .= ("0.1.0" :: Text)
        , "min_runner" .= ("0.1.0" :: Text)
        , "runner_plugin_api" .= ("v1" :: Text)
        ]
    , "capabilities" .= cmCapabilities manifest
    , "verification" .= object
        [ "status" .= ("draft" :: Text)
        ]
    ]
