module LanguageServer.IdePurescript.Imports where

import Prelude

import Control.Error.Util (hush)
import Control.Monad.Except (runExcept)
import Data.Array (fold, singleton, (:))
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (all)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Newtype (un, unwrap)
import Data.Nullable (toNullable)
import Data.Nullable as Nullable
import Data.String.Utils (lines, startsWith)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Foreign (Foreign, readString, unsafeToForeign)
import IdePurescript.Modules (ImportResult(..), addExplicitImport, addModuleImport, addQualifiedImport, organiseModuleImports)
import IdePurescript.PscIde (getAvailableModules)
import IdePurescript.PscIdeServer (ErrorLevel(..), Notify)
import LanguageServer.DocumentStore (getDocument)
import LanguageServer.Handlers (applyEdit)
import LanguageServer.IdePurescript.Config (autocompleteAddImport, preludeModule)
import LanguageServer.IdePurescript.Types (ServerState(..))
import LanguageServer.Text (makeMinimalWorkspaceEdit)
import LanguageServer.TextDocument (TextDocument, getText, getUri, getVersion)
import LanguageServer.Types (Diagnostic(..), Position(..), DocumentStore, DocumentUri(DocumentUri), Range(..), Settings, WorkspaceEdit)
import LanguageServer.Uri (uriToFilename)
import PscIde.Command as C

addCompletionImport :: Notify -> DocumentStore -> Settings -> ServerState -> Array Foreign -> Aff Foreign
addCompletionImport = addCompletionImport' mempty

addCompletionImport' :: WorkspaceEdit -> Notify -> DocumentStore -> Settings -> ServerState -> Array Foreign -> Aff Foreign
addCompletionImport' existingEdit log docs config state@(ServerState { port, modules, conn }) args = do
  let shouldAddImport = autocompleteAddImport config
  case conn, (runExcept <<< readString) <$> args, shouldAddImport of
    Just conn, [ Right identifier, mod, qual, Right uriRaw, Right ns ], true -> do
      let uri = DocumentUri uriRaw
      doc <- liftEffect $ getDocument docs uri
      version <- liftEffect $ getVersion doc
      text <- liftEffect $ getText doc
      edit <- addCompletionImportEdit log docs config state { identifier, mod: hush mod, qual: hush qual, uri } doc version text (parseNS ns)
      case edit of
        Right edits -> do
          void $ applyEdit conn (fold $ existingEdit : edits)
          pure $ unsafeToForeign $ toNullable Nothing
        Left res -> do
          void $ applyEdit conn existingEdit
          pure res
    Just conn, _, _ ->  do
      void $ applyEdit conn existingEdit
      pure $ unsafeToForeign $ toNullable Nothing
    _, _, _ -> pure $ unsafeToForeign $ toNullable Nothing

type CompletionImportArgs =
  {
    identifier:: String
  , mod :: Maybe String
  , qual :: Maybe String
  , uri :: DocumentUri
  }

parseNS :: String -> Maybe C.Namespace
parseNS "NSValue" = Just C.NSValue
parseNS "NSKind" = Just C.NSKind
parseNS "NSType" = Just C.NSType
parseNS _ = Nothing

showNS :: C.Namespace -> String
showNS C.NSValue = "NSValue"
showNS C.NSKind = "NSKind"
showNS C.NSType = "NSType"


addCompletionImportEdit :: Notify -> DocumentStore -> Settings -> ServerState
 -> CompletionImportArgs -> TextDocument -> Number -> String -> Maybe C.Namespace
 -> Aff (Either Foreign (Array WorkspaceEdit))
addCompletionImportEdit log docs config state@(ServerState { port, modules, conn, clientCapabilities }) { identifier, mod, qual, uri } doc version text ns = do
  let prelude = preludeModule config
  case port of
    Just port -> do
      { state: modulesState', result } <-
        case mod, qual of
          Just mod', Just qual' | noModule (isSameQualified mod' qual') ->
            addQualifiedImport modules port (un DocumentUri uri) text mod' qual'
          Just mod', Nothing | mod' == prelude && noModule (isSameUnqualified prelude) ->
            addOpenImport modules port (un DocumentUri uri) text mod'
          mod', qual' -> do
            liftEffect $ log Info $ "Adding import of " <> identifier <> " from " <> show mod' <> " with type filter " <> show (showNS <$>  ns)
            addExplicitImport modules port (un DocumentUri uri) text mod' qual' identifier ns
      case result of
        UpdatedImports newText -> do
          let edit = makeMinimalWorkspaceEdit clientCapabilities uri version text newText
          pure $ Right $ maybe [] singleton edit
        AmbiguousImport imps -> liftEffect do
          log Warning "Found ambiguous imports"
          pure $ Left $ unsafeToForeign $ (\(C.TypeInfo { module' }) -> module') <$> imps
        -- Failed import is not unusual - e.g. already existing import will hit this case.
        FailedImport -> pure $ Right []
    _ -> pure $ Right [] 

    where

    noModule f = all (not f <<< unwrap) modules.modules
    isSameQualified mod qual = case _ of
      { moduleName: mod', qualifier: Just qual'} -> mod == mod' && qual == qual'
      _ -> false

    isSameUnqualified mod = case _ of
      { moduleName, qualifier: Nothing } -> mod == moduleName
      _ -> false

    -- addModuleImport discards the result data type and wraps it in Maybe. We
    -- need to add it back for the types to unify.
    addOpenImport modules port uri text mod =
      addModuleImport modules port uri text mod <#> case _ of
        Just r -> r { result = UpdatedImports r.result }
        Nothing -> { state: modules, result: FailedImport }


addModuleImport' :: Notify -> DocumentStore -> Settings -> ServerState -> Array Foreign -> Aff Foreign
addModuleImport' log docs config state args = do
  let ServerState { port, modules, conn, clientCapabilities } = state
  case port, (runExcept <<< readString) <$> args of
    Just port', [ Right mod', qual', Right uri ] -> do
      doc <- liftEffect $ getDocument docs (DocumentUri uri)
      version <- liftEffect $ getVersion doc
      text <- liftEffect $ getText doc
      fileName <- liftEffect $ uriToFilename $ DocumentUri uri
      res <- addModuleImport modules port' fileName text mod'
      case res of
        Just { result } -> do
          let edit = makeMinimalWorkspaceEdit clientCapabilities (DocumentUri uri) version text result
          case conn, edit of
            Just conn', Just edit' -> void $ applyEdit conn' edit'
            _, _ -> pure unit
        _ -> pure unit
      pure successResult

    _, args'-> do
      liftEffect $ log Info $ show args'
      pure successResult

    where
    successResult = unsafeToForeign $ toNullable Nothing


getAllModules :: Notify -> DocumentStore -> Settings -> ServerState -> Array Foreign -> Aff Foreign
getAllModules log docs config state args =
  case state of
    ServerState { port: Just port, modules, conn } ->
      unsafeToForeign <$> getAvailableModules port
    _ -> do
      liftEffect $ log Error "Fail case"
      pure $ unsafeToForeign []

organiseImports :: Notify -> DocumentStore -> Settings -> ServerState -> Array Foreign -> Aff Foreign
organiseImports log docs config state args = do
  let ServerState { port, modules, conn, clientCapabilities } = state
  case port, (runExcept <<< readString) <$> args of
    Just port', [ Right uri ] -> do
      doc <- liftEffect $ getDocument docs (DocumentUri uri)
      version <- liftEffect $ getVersion doc
      text <- liftEffect $ getText doc
      fileName <- liftEffect $ uriToFilename $ DocumentUri uri
      res <- organiseModuleImports log modules port' fileName text
      case res of
        Just { result } -> do
          let edit = makeMinimalWorkspaceEdit clientCapabilities (DocumentUri uri) version text result
          case conn, edit of
            Just conn', Just edit' -> void $ applyEdit conn' edit'
            _, _ -> pure unit
        _ -> pure unit
      pure successResult

    _, args'-> do
      liftEffect $ log Info $ show args'
      pure successResult

    where
    successResult = unsafeToForeign $ toNullable Nothing

organiseImportsDiagnostic :: ServerState -> (ErrorLevel -> String -> Effect Unit) -> TextDocument -> Aff (Array Diagnostic)
organiseImportsDiagnostic s logError document = do
  let uri = getUri document
  version <- liftEffect $ getVersion document
  text <- liftEffect $ getText document
  fileName <- liftEffect $ uriToFilename uri
  res <- organiseModuleImports logError (un ServerState s).modules (fromMaybe 0 (un ServerState s).port) fileName text
  let lastImportLine = Array.findLastIndex (startsWith "import ") (lines text)
  liftEffect $ case res of
    -- Should we offer reorganise imports - will it do anything?
    Just { result } | result /= text -> do
      pure $ Array.singleton $ Diagnostic
        { range: Range { start: Position { line: 0, character: 0 }, end: Position { line: fromMaybe 0 lastImportLine, character: 0 } }
        , severity: Nullable.toNullable $ Just 4
        , code: Nullable.toNullable $ Just "HintOrganiseImports"
        , source: Nullable.toNullable Nothing
        , message: "File imports are not in the compiler's standard formatting"
        }
    _ -> pure []