{-# LANGUAGE DeriveDataTypeable, TypeFamilies, TemplateHaskell,
             FlexibleInstances, FlexibleContexts, MultiParamTypeClasses,
             TypeOperators, TypeSynonymInstances #-}
module Distribution.Server.State where

import Distribution.Server.Instances ()

import Distribution.Server.Packages.State
import Distribution.Server.Packages.Preferred (PreferredVersions)
import Distribution.Server.Packages.Reverse (ReverseIndex)
import Distribution.Server.Packages.Downloads (DownloadCounts)
import Distribution.Server.Packages.Tag (PackageTags)
import Distribution.Server.BuildReport.BuildReports (BuildReports)
import Distribution.Server.BuildReport.State ()
import Distribution.Server.Users.Users (Users)
import Distribution.Server.Users.State (HackageAdmins, IndexUsers)
import Distribution.Server.Distributions.State (Distros)
import Distribution.Server.Util.TarIndex (TarIndexMap)

import Happstack.State

import Data.Typeable

data HackageEntryPoint = HackageEntryPoint deriving Typeable
data Core = Core deriving Typeable
instance Version Core
$(deriveSerialize ''Core)

instance Version HackageEntryPoint
$(deriveSerialize ''HackageEntryPoint)

-- Core: PackagesState, Users, TarIndexMap
instance Component Core where
    type Dependencies Core = PackagesState :+: Users :+: HackageAdmins :+: End
    initialValue = Core
$(mkMethods ''Core [])

instance Component HackageEntryPoint where
    type Dependencies HackageEntryPoint
        = Core :+: Documentation :+:
          BuildReports :+: Distros :+: TarIndexMap :+:
          PackageUpload :+: CandidatePackages :+: 
          PreferredVersions :+: ReverseIndex :+:
          DownloadCounts :+: PackageTags :+:
          IndexUsers :+: End
    initialValue = HackageEntryPoint

$(mkMethods ''HackageEntryPoint [])

