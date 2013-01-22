{-# LANGUAGE RankNTypes, NamedFieldPuns, RecordWildCards #-}
module Distribution.Server.Features.PackageCandidates (
    PackageCandidatesFeature(..),
    PackageCandidatesResource(..),
    initPackageCandidatesFeature,

    CandidateRender(..),
    CandPkgInfo(..),
  ) where

import Distribution.Server.Framework

import Distribution.Server.Features.PackageCandidates.Types
import Distribution.Server.Features.PackageCandidates.State

import Distribution.Server.Features.Core
import Distribution.Server.Features.Upload
import Distribution.Server.Features.Users

import Distribution.Server.Packages.Types
import Distribution.Server.Packages.Render
import qualified Distribution.Server.Users.Types as Users
import qualified Distribution.Server.Users.Group as Group
import qualified Distribution.Server.Framework.BlobStorage as BlobStorage
import qualified Distribution.Server.Packages.PackageIndex as PackageIndex
import Distribution.Server.Packages.PackageIndex (PackageIndex)
import qualified Distribution.Server.Framework.ResponseContentTypes as Resource
import Distribution.Server.Framework.BackupRestore (restoreBackupUnimplemented)

import qualified Distribution.Server.Util.ServeTarball as ServeTarball
import Data.TarIndex (TarIndex)
import qualified Data.TarIndex as TarIndex
import qualified Text.PrettyPrint.HughesPJ as Pretty (render)

import Distribution.Text
import Distribution.Package

import Data.Version
import Text.XHtml.Strict (unordList, h3, (<<), toHtml)
import Data.Function (fix)
import Data.List (find)
import Data.Maybe (listToMaybe, catMaybes)
import Data.Time.Clock (getCurrentTime)

data PackageCandidatesFeature = PackageCandidatesFeature {
    candidatesFeatureInterface :: HackageFeature,

    candidatesResource :: PackageCandidatesResource,

    -- queries
    queryGetCandidateIndex :: MonadIO m => m (PackageIndex CandPkgInfo),

    postCandidate         :: ServerPartE Response,
    postPackageCandidate  :: DynamicPath -> ServerPartE Response,
    putPackageCandidate   :: DynamicPath -> ServerPartE Response,
    doDeleteCandidate     :: DynamicPath -> ServerPartE Response,
    uploadCandidate       :: (PackageId -> Bool) -> ServerPartE CandPkgInfo,
    publishCandidate      :: DynamicPath -> Bool -> ServerPartE UploadResult,
    checkPublish          :: PackageIndex PkgInfo -> CandPkgInfo -> Maybe ErrorResponse,
    candidateRender       :: CandPkgInfo -> IO CandidateRender,

    withCandidatePath :: forall a. DynamicPath -> (CandidatePackages -> CandPkgInfo -> ServerPartE a) -> ServerPartE a,
    withCandidate     :: forall a. PackageId -> (CandidatePackages -> Maybe CandPkgInfo -> [CandPkgInfo] -> ServerPartE a) -> ServerPartE a,
    withCandidates    :: forall a. PackageName -> (CandidatePackages -> [CandPkgInfo] -> ServerPartE a) -> ServerPartE a
}

instance IsHackageFeature PackageCandidatesFeature where
    getFeatureInterface = candidatesFeatureInterface


data PackageCandidatesResource = PackageCandidatesResource {
    candidatesPage        :: Resource,
    candidatePage         :: Resource,
    packageCandidatesPage :: Resource,
    publishPage           :: Resource,
    candidateCabal        :: Resource,
    candidateTarball      :: Resource,
    candidateContents     :: Resource,
    candidateChangeLog    :: Resource,
    -- There can also be build reports as well as documentation for proposed
    -- versions.
    -- These features check for existence of a package in the *main* index,
    -- but it should be possible to hijack their indices to support candidates,
    -- perhaps by them having a Filter for whether a package-version exists
    -- (since they don't need any other info than the PackageId).
    -- Unfortunately, some problems exist when both a candidate and actual version
    -- of the same package exist simultaneously, so may want to hook into
    -- UploadFeature's canUploadPackage to ensure this won't happen, and to
    -- force deletion on publication.
    candidatesUri         :: String -> String,
    candidateUri          :: String -> PackageId -> String,
    packageCandidatesUri  :: String -> PackageName -> String,
    publishUri            :: String -> PackageId -> String,
    candidateTarballUri   :: PackageId -> String,
    candidateCabalUri     :: PackageId -> String,
    candidateChangeLogUri :: PackageId -> String
}

-- candidates can be published at any time; there can be multiple candidates per package
-- they can be deleted, but it's not required

data CandidateRender = CandidateRender {
    candPackageRender :: PackageRender,
    renderWarnings :: [String],
    hasIndexedPackage :: Bool
}


-- URI generation (string-based), using maps; user groups
initPackageCandidatesFeature :: ServerEnv
                 -> UserFeature -> CoreFeature -> UploadFeature
                 -> IO PackageCandidatesFeature
initPackageCandidatesFeature env@ServerEnv{serverStateDir} user core upload = do
    candidatesState <- candidatesStateComponent serverStateDir
    return $ candidatesFeature env user core upload candidatesState

candidatesStateComponent :: FilePath -> IO (StateComponent CandidatePackages)
candidatesStateComponent stateDir = do
  st <- openLocalStateFrom (stateDir </> "db" </> "CandidatePackages") initialCandidatePackages
  return StateComponent {
      stateDesc    = "Candidate packages"
    , getState     = query st GetCandidatePackages
    , putState     = update st . ReplaceCandidatePackages
    , acidState    = st
    , resetState   = candidatesStateComponent
      -- TODO: backup
    , backupState  = \_ -> []
    , restoreState = restoreBackupUnimplemented
    , getStateSize = memSize <$> query st GetCandidatePackages
  }

candidatesFeature :: ServerEnv
             -> UserFeature
             -> CoreFeature
             -> UploadFeature
             -> StateComponent CandidatePackages
             -> PackageCandidatesFeature

candidatesFeature ServerEnv{serverBlobStore = store}
             UserFeature{..} CoreFeature{..}
             UploadFeature{..}
             candidatesState
  = PackageCandidatesFeature{..}
  where
    candidatesFeatureInterface = (emptyHackageFeature "candidates") {
        featureDesc = "Support for package candidates"
      , featureResources =
          map ($candidatesResource) [
              candidatesPage
            , candidatePage
            , publishPage
            , candidateCabal
            , candidateTarball
            , candidateContents
            , candidateChangeLog
            ]
      , featureState = [abstractStateComponent candidatesState]
      }

    queryGetCandidateIndex :: MonadIO m => m (PackageIndex CandPkgInfo)
    queryGetCandidateIndex = return . candidateList =<< queryState candidatesState GetCandidatePackages

    candidatesResource = fix $ \r -> PackageCandidatesResource {
        candidatesPage = resourceAt "/packages/candidates/.:format"
      , candidatePage = (resourceAt "/package/:package/candidate.:format") {
            resourceDesc = [(GET, "Show basic package candidate page")]
          , resourceGet  = [("html", basicCandidatePage r)]
          }
      , packageCandidatesPage = resourceAt "/package/:package/candidates/.:format"
      , publishPage = resourceAt "/package/:package/candidate/publish.:format"
      , candidateCabal = (resourceAt "/package/:package/candidate/:cabal.cabal") {
            resourceDesc = [(GET, "Candidate .cabal file")]
          , resourceGet  = [("cabal", serveCandidateCabal)]
          }
      , candidateTarball = (resourceAt "/package/:package/candidate/:tarball.tar.gz") {
            resourceDesc = [(GET, "Candidate tarball")]
          , resourceGet  = [("tarball", serveCandidateTarball)]
          }
      , candidateContents = (resourceAt "/package/:package/candidate/src/..") {
            resourceGet = [("", serveContents)]
          }
      , candidateChangeLog = (resourceAt "/package/:package/candidate/changelog") {
            resourceGet = [("changelog", serveChangeLog)]
          }
      , candidatesUri = \format ->
          renderResource (candidatesPage r) [format]
      , candidateUri  = \format pkgid ->
          renderResource (candidatePage r) [display pkgid, format]
      , packageCandidatesUri = \format pkgname ->
          renderResource (packageCandidatesPage r) [display pkgname, format]
      , publishUri = \format pkgid ->
          renderResource (publishPage r) [display pkgid, format]
      , candidateTarballUri = \pkgid ->
          renderResource (candidateTarball r) [display pkgid, display pkgid]
      , candidateCabalUri = \pkgid ->
          renderResource (candidateCabal r) [display pkgid, display (packageName pkgid)]
      , candidateChangeLogUri = \pkgid ->
          renderResource (candidateChangeLog candidatesResource) [display pkgid, display (packageName pkgid)]
      }

    basicCandidatePage :: PackageCandidatesResource -> DynamicPath -> ServerPart Response
    basicCandidatePage r dpath = runServerPartE $ --TODO: use something else for nice html error pages
                                 withPackageId dpath $ \pkgid ->
                                 withCandidate pkgid $ \_ mpkg _ ->
                                 ok . toResponse . Resource.XHtml $ case mpkg of
        Nothing  -> toHtml $ "A candidate for " ++ display pkgid ++ " doesn't exist"
        Just pkg -> toHtml [ h3 << "Downloads"
                           , toHtml (section pkg)
                           , h3 << "Warnings"
                           , case candWarnings pkg of
                                [] -> toHtml "No warnings"
                                warnings -> unordList warnings
                           ]
      where section cand = basicPackageSection (candidateCabalUri r)
                                               (candidateTarballUri r)
                                               (candPkgInfo cand)

    postCandidate :: ServerPartE Response
    postCandidate = do
        pkgInfo <- uploadCandidate (const True)
        seeOther (candidateUri candidatesResource "" $ packageId pkgInfo) (toResponse ())

    -- POST to /:package/candidates/
    postPackageCandidate :: DynamicPath -> ServerPartE Response
    postPackageCandidate dpath = withPackageName dpath $ \name -> do
        pkgInfo <- uploadCandidate ((==name) . packageName)
        seeOther (candidateUri candidatesResource "" $ packageId pkgInfo) (toResponse ())

    -- PUT to /:package-version/candidate
    -- FIXME: like delete, PUT shouldn't redirect
    putPackageCandidate :: DynamicPath -> ServerPartE Response
    putPackageCandidate dpath = withPackageId dpath $ \pkgid -> do
        guard (packageVersion pkgid /= Version [] [])
        pkgInfo <- uploadCandidate (==pkgid)
        seeOther (candidateUri candidatesResource "" $ packageId pkgInfo) (toResponse ())

    -- FIXME: DELETE should not redirect, but rather return ServerPartE ()
    doDeleteCandidate :: DynamicPath -> ServerPartE Response
    doDeleteCandidate dpath = withCandidatePath dpath $ \_ candidate -> do
        withPackageAuth candidate $ \_ _ -> do
        void $ updateState candidatesState $ DeleteCandidate (packageId candidate)
        seeOther (packageCandidatesUri candidatesResource "" $ packageName candidate) $ toResponse ()

    serveCandidateTarball :: DynamicPath -> ServerPart Response
    serveCandidateTarball dpath = runServerPartE $
                                        withPackageTarball dpath $ \pkgid ->
                                        withCandidate pkgid $ \_ mpkg _ -> case mpkg of
        Nothing -> mzero -- candidate  does not exist
        Just pkg -> case pkgTarball (candPkgInfo pkg) of
            [] -> mzero --candidate's tarball does not exist
            ((tb, _):_) -> do
                let blobId = pkgTarballGz tb
                file <- liftIO $ BlobStorage.fetch store blobId
                ok $ toResponse $ Resource.PackageTarball file blobId (pkgUploadTime $ candPkgInfo pkg)

    --withFormat :: DynamicPath -> (String -> a) -> a
    serveCandidateCabal :: DynamicPath -> ServerPart Response
    serveCandidateCabal dpath =
        runServerPartE $ --TODO: use something else for nice html error pages
        withCandidatePath dpath $ \_ pkg -> do
            guard (lookup "cabal" dpath == Just (display $ packageName pkg))
            return $ toResponse (Resource.CabalFile (cabalFileByteString $ pkgData $ candPkgInfo pkg))

    uploadCandidate :: (PackageId -> Bool) -> ServerPartE CandPkgInfo
    uploadCandidate isRight = do
        regularIndex <- queryGetPackageIndex
        -- ensure that the user has proper auth if the package exists
        (pkgInfo, uresult) <- extractPackage (\uid info -> combineErrors $ sequence
          [ processCandidate isRight regularIndex uid info
          , runUserFilter uid])
        let candidate = CandPkgInfo {
                candInfoId = packageId pkgInfo,
                candPkgInfo = pkgInfo,
                candWarnings = uploadWarnings uresult,
                candPublic = True -- do withDataFn
            }
        void $ updateState candidatesState $ AddCandidate candidate
        let group = packageMaintainers [("package", display $ packageName pkgInfo)]
        exists <- liftIO $ Group.groupExists group
        when (not exists) $ liftIO $ Group.addUserList group (pkgUploadUser pkgInfo)
        return candidate
      where combineErrors = fmap (listToMaybe . catMaybes)

    -- | Helper function for uploadCandidate.
    processCandidate :: (PackageId -> Bool) -> PackageIndex PkgInfo -> Users.UserId -> UploadResult -> IO (Maybe ErrorResponse)
    processCandidate isRight state uid res = do
        let pkg = packageId (uploadDesc res)
        if not (isRight pkg)
          then uploadFailed "Name of package or package version does not match"
          else do
            pkgGroup <- getPackageGroup (packageName pkg)
            if uploadsRestrictedToMaintainers && packageExists state pkg && not (uid `Group.member` pkgGroup)
              then uploadFailed "Not authorized to upload a candidate for this package"
              else return Nothing
      where uploadFailed = return . Just . ErrorResponse 403 "Upload failed" . return . MText

    publishCandidate :: DynamicPath -> Bool -> ServerPartE UploadResult
    publishCandidate dpath doDelete = do
        packages <- queryGetPackageIndex
        withCandidatePath dpath $ \_ candidate -> do
        -- check authorization to upload - must already be a maintainer
        withPackageAuth candidate $ \uid _ -> do
        -- check if package or later already exists
        case checkPublish packages candidate of
          Just failed -> throwError failed
          Nothing -> do
            -- run filters
            let pkgInfo = candPkgInfo candidate
                uresult = UploadResult (pkgDesc pkgInfo) (cabalFileByteString $ pkgData pkgInfo) (candWarnings candidate)
                uploadFilter = combineErrors $ runFilter'' canUploadPackage uid uresult
            merror <- liftIO $ combineErrors $ sequence [runUserFilter uid, uploadFilter]
            case merror of
              Just failed -> throwError failed
              Nothing -> do
                uploadData <- fmap (flip (,) uid) (liftIO getCurrentTime)
                let pkgInfo' = PkgInfo {
                        pkgInfoId     = packageId candidate,
                        pkgData       = pkgData pkgInfo,
                        pkgTarball    = case pkgTarball pkgInfo of
                            ((blobId, _):_) -> [(blobId, uploadData)]
                            [] -> [], -- this shouldn't happen, but let's keep this part total anyway
                        pkgUploadData = uploadData,
                        pkgDataOld    = []
                    }
                success <- liftIO $ doAddPackage pkgInfo'
                if success
                  then do
                    -- delete when requested: "moving" the resource
                    -- should this be required? (see notes in PackageCandidatesResource)
                    when doDelete $ updateState candidatesState $ DeleteCandidate (packageId candidate)
                    return uresult
                  else errForbidden "Upload failed" [MText "Package already exists."]
      where combineErrors = fmap (listToMaybe . catMaybes)


    -- | Helper function for publishCandidate that ensures it's safe to insert into the main index.
    checkPublish :: PackageIndex PkgInfo -> CandPkgInfo -> Maybe ErrorResponse
    checkPublish packages candidate = do
        let pkgs = PackageIndex.lookupPackageName packages (packageName candidate)
            candVersion = packageVersion candidate
        case find ((== candVersion) . packageVersion) pkgs of
            Just {} -> Just $ ErrorResponse 403 "Publish failed" [MText "Package name and version already exist in the database"]
            Nothing  -> Nothing

    ------------------------------------------------------------------------------
{-

       changeLogRes <- lookupChangeLog store info
        , rendChangeLogUri = case changeLogRes of
                               Right _ -> Just (pkgUri </> "changelog")
                               _ -> Nothing
-}

    candidateRender :: CandPkgInfo -> IO CandidateRender
    candidateRender cand = do
           users  <- queryGetUserDb
           index  <- queryGetPackageIndex
           -- TODO: we should check if there is a changelog, but lookupChangelog
           -- is a feature of PackageContents, so we cannot use it here. We
           -- could duplicate it here, but there appears to be a *lot* of
           -- duplication already between that feature and this one. We should
           -- fix that.
           let showChangeLogLink = True
           render <- doPackageRender users (candPkgInfo cand) showChangeLogLink
           return $ CandidateRender {
             candPackageRender = render { rendPkgUri = rendPkgUri render ++ "/candidate" },
             renderWarnings = candWarnings cand,
             hasIndexedPackage = not . null $ PackageIndex.lookupPackageName index (packageName cand)
           }

    ------------------------------------------------------------------------------
    withCandidatePath :: DynamicPath -> (CandidatePackages -> CandPkgInfo -> ServerPartE a) -> ServerPartE a
    withCandidatePath dpath func = withPackageId dpath $ \pkgid -> withCandidate pkgid $ \state mpkg _ -> case mpkg of
        Nothing  -> errNotFound "Package not found" [MText $ "Candidate for " ++ display pkgid ++ " does not exist"]
        Just pkg -> func state pkg

    withCandidate :: PackageId -> (CandidatePackages -> Maybe CandPkgInfo -> [CandPkgInfo] -> ServerPartE a) -> ServerPartE a
    withCandidate pkgid func = do
        state <- queryState candidatesState GetCandidatePackages
        let pkgs = PackageIndex.lookupPackageName (candidateList state) (packageName pkgid)
        func state (find ((==pkgid) . packageId) pkgs) pkgs

    withCandidates :: PackageName -> (CandidatePackages -> [CandPkgInfo] -> ServerPartE a) -> ServerPartE a
    withCandidates name func = withCandidate (PackageIdentifier name $ Version [] []) $ \state _ infos -> func state infos

    withCandidatePath' :: DynamicPath -> (PkgInfo -> ServerPartE a) -> ServerPartE a
    withCandidatePath' dpath k = withCandidatePath dpath $ \_ pkg -> k (candPkgInfo pkg)

{-------------------------------------------------------------------------------
  EVERYTHING BELOW IS A DIRECT DUPLICATE OF FUNCTIONALITY IN PACKAGECONTENTS.
  WE SHOULD FACTOR THIS OUT.
-------------------------------------------------------------------------------}

    serveContents :: DynamicPath -> ServerPart Response
    serveContents = serveContents' withCandidatePath'

    serveChangeLog :: DynamicPath -> ServerPart Response
    serveChangeLog = serveChangeLog' withCandidatePath'

    serveChangeLog' :: (DynamicPath -> ((PkgInfo -> ServerPartE Response) -> ServerPartE Response))
                    -> DynamicPath -> ServerPart Response
    serveChangeLog' with_pkg_path dpath = runServerPartE $ with_pkg_path dpath $ \pkg -> do
        res <- liftIO $ lookupChangeLog store pkg
        case res of
          Left err -> errNotFound "Changelog not found" [MText err]
          Right (fp, offset, name) -> liftIO $ ServeTarball.serveTarEntry fp offset name

    serveContents' :: (DynamicPath -> ((PkgInfo -> ServerPartE Response) -> ServerPartE Response))
                   -> DynamicPath -> ServerPart Response
    serveContents' with_pkg_path dpath = runServerPartE $ withContents $ \pkgid tarball index -> do
        -- if given a directory, the default page is index.html
        -- the default directory prefix is the package name itself (including the version)
        ServeTarball.serveTarball ["index.html"] (display pkgid) tarball index
      where
        withContents :: (PackageId -> FilePath -> TarIndex -> ServerPartE Response) -> ServerPartE Response
        withContents func = with_pkg_path dpath $ \pkg ->
            case lookupTarballAndConstructTarIndex store pkg of
                Nothing -> fail "Could not serve package contents: no tarball exists."
                Just io -> liftIO io >>= \(fp, index) -> func (packageId pkg) fp index



-- TODO: This should go completely. We should cache tar indices, not
-- reconstruct them all the time.
lookupTarballAndConstructTarIndex :: BlobStorage -> PkgInfo -> Maybe (IO (FilePath, TarIndex.TarIndex))
lookupTarballAndConstructTarIndex store pkgInfo =
    case pkgTarball pkgInfo of
        [] -> Nothing
        ((tb, _):_) -> Just $
            do let blobId = pkgTarballNoGz tb
                   fp = BlobStorage.filepath store blobId
               index <- ServeTarball.constructTarIndexFromFile fp
               return (fp, index)

lookupChangeLog :: BlobStorage -> PkgInfo -> IO (Either String (FilePath, TarIndex.TarEntryOffset, String))
lookupChangeLog store pkgInfo = case lookupTarballAndConstructTarIndex store pkgInfo of
        Nothing -> return $ Left "Could not extract changelog: no tarball exists."
        Just io ->
            do (fp, index) <- io
               case msum $ map (lookupFile index) candidates of
                 Just (name, offset) -> return $ Right (fp, offset, name)
                 Nothing ->
                     do let msg = "No changelog found, files considered: " ++ show candidates
                        return $ Left msg
    where
      lookupFile index fname =
          do entry <- TarIndex.lookup index fname
             case entry of
               TarIndex.TarFileEntry offset -> return (fname, offset)
               _ -> fail "is a directory"
      candidates =
          let l = ["ChangeLog", "CHANGELOG", "CHANGE_LOG", "Changelog", "changelog"]
              pkgId = Pretty.render $ disp (pkgInfoId pkgInfo)
          in map (pkgId </>) $ map (++ ".html") l ++ l

