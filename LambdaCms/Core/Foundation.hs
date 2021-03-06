{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE ViewPatterns          #-}
{-# OPTIONS_GHC -fno-warn-orphans  #-}

module LambdaCms.Core.Foundation where

import           Control.Applicative        ((<$>))
import           Control.Arrow              ((&&&))
import           Data.ByteString            (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LB (concat, toStrict)
import           Data.List                  (find, sortBy)
import           Data.Maybe                 (catMaybes, isJust)
import           Data.Monoid                ((<>))
import           Data.Ord                   (comparing)
import           Data.Set                   (Set)
import qualified Data.Set                   as S (empty, intersection, null)
import           Data.Text                  (Text, concat, intercalate, pack,
                                             unpack)
import qualified Data.Text                  as T
import           Data.Text.Encoding         (decodeUtf8)
import           Data.Time                  (getCurrentTime)
import           Data.Time.Format.Human
import           Data.Traversable           (forM)
import           Database.Persist.Sql       (SqlBackend)
import           LambdaCms.Core.Message     (CoreMessage, defaultMessage,
                                             dutchMessage, englishMessage)
import qualified LambdaCms.Core.Message     as Msg
import           LambdaCms.Core.Models
import           LambdaCms.Core.Settings
import           LambdaCms.I18n
import           Network.Gravatar           (GravatarOptions (..), Size (..),
                                             def, gravatar)
import           Network.Mail.Mime
import           Network.Wai                (requestMethod)
import           Text.Hamlet                (hamletFile)
import           Yesod
import           Yesod.Auth

-- | Foundation type.
data CoreAdmin = CoreAdmin

-- | Denotes what kind of user is allowed to perform an action.
data Allow a = Unauthenticated -- ^ Allow anyone (no authentication required).
             | Authenticated   -- ^ Allow any authenticated user.
             | Roles a         -- ^ Allow anyone who as at least one matching role.
             | Nobody          -- ^ Allow nobody.

-- | A menu item, also see 'adminMenu'.
--
-- > MenuItem (SomeMessage MsgProduct) (ProductAdminOverviewR) "shopping-cart"
data AdminMenuItem master = MenuItem
                            { label :: SomeMessage master -- ^ The text of the item (what the user sees).
                            , route :: Route master       -- ^ The Route to which it points.
                            , icon  :: Text               -- ^ A <http://glyphicons.bootstrapcheatsheets.com glyphicon> without the ".glyphicon-" prefix.
                            }

mkYesodSubData "CoreAdmin" $(parseRoutesFile "config/routes")

instance LambdaCmsAdmin master => RenderMessage master CoreMessage where
  renderMessage = renderCoreMessage

-- | Fairly complex "handler" type, allowing persistent queries on the master's db connection, hereby simplified.
type CoreHandler a = forall master. LambdaCmsAdmin master => HandlerT CoreAdmin (HandlerT master IO) a

-- | Fairly complex Form type, hereby simplified.
type CoreForm a = forall master. LambdaCmsAdmin master => Html -> MForm (HandlerT master IO) (FormResult a, WidgetT master IO ())

class ( YesodAuth master
      , AuthId master ~ Key User
      , AuthEntity master ~ User
      , YesodAuthPersist master
      , YesodPersistBackend master ~ SqlBackend
      , ParseRoute master
      , Ord (Roles master)     -- Roles must be Ord to be a Set
      , Enum (Roles master)    -- Roles must be Enum to be able to do [minBound .. maxBound]
      , Bounded (Roles master) -- see Enum
      , Show (Roles master)    -- Roles must be Show to grant/revoke via the UI
      , Eq (Roles master)      -- Roles must be Eq for Set intersection
      ) => LambdaCmsAdmin master where

    -- | A type denoting the roles a user can have on the website.
    -- The implementation must have a datatype representing those roles. For example:
    --
    -- > type Roles MyApp = MyRoles
    --
    -- Then, in the base app, MyRoles can be:
    --
    -- @
    -- data MyRoles = Admin
    --              | SuperUser
    --              | Blogger
    --              deriving (Show, Eq, Read, Ord, Enum, Bounded)
    -- @
    type Roles master

    -- | Get all roles of a user as a Set.
    getUserRoles :: Key User -> HandlerT master IO (Set (Roles master))

    -- | Replace the current roles of a user by the given Set.
    setUserRoles :: Key User -> Set (Roles master) -> HandlerT master IO ()

    mayAssignRoles :: HandlerT master IO Bool

    -- | Gives the default roles a user should have on create
    defaultRoles :: HandlerT master IO (Set (Roles master))
    defaultRoles = return S.empty

    -- | See if a user is authorized to perform an action.
    isAuthorizedTo :: master                     -- Needed to make function injective.
                   -> Maybe (Set (Roles master)) -- ^ Set of roles the user has.
                   -> Allow (Set (Roles master)) -- ^ Set of roles allowed to perform the action.
                   -> AuthResult
    isAuthorizedTo _ _           Nobody          = Unauthorized "Access denied."
    isAuthorizedTo _ _           Unauthenticated = Authorized
    isAuthorizedTo _ (Just _)    Authenticated   = Authorized
    isAuthorizedTo _ Nothing     _               = AuthenticationRequired
    isAuthorizedTo _ (Just urs) (Roles rrs)    = do
      case (not . S.null $ urs `S.intersection` rrs) of
        True -> Authorized -- non-empty intersection means authorized
        False -> Unauthorized "Access denied."

    -- | Get the 'Allow' type needed for this action.
    -- The default is that no one can do anything.
    actionAllowedFor :: Route master -- ^ The action (or route).
                     -> ByteString -- ^ The request method (e/g: GET, POST, DELETE, ...).
                                   -- Knowing /which/ method is used allows for more fine grained
                                   -- permissions than only knowing whether it is /write/ request.
                     -> Allow (Set (Roles master))
    actionAllowedFor _ _ = Nobody

    -- | Both coreR and authR are used to navigate to a different controller.
    -- It saves you from putting "getRouteToParent" everywhere.
    coreR :: Route CoreAdmin -> Route master
    authR :: Route Auth -> Route master

    -- | Gives the route which LambdaCms should use as the master site homepage.
    masterHomeR :: Route master

    adminTitle :: SomeMessage master
    adminTitle = SomeMessage Msg.LambdaCms

    -- | Gives a widget to use as the welcome banner on the admin dashboard
    welcomeWidget :: Maybe (WidgetT master IO ())
    welcomeWidget = Just $ do
        Entity _ user <- handlerToWidget requireAuth
        messageRenderer <- getMessageRender
        $(widgetFile "admin-welcome")

    -- | Applies some form of layout to the contents of an admin section page.
    adminLayout :: WidgetT master IO () -> HandlerT master IO Html
    adminLayout widget = do
        auth <- requireAuth
        mCurrentR <- getCurrentRoute
        mmsg <- getMessage
        can <- getCan

        let am = filter (isJust . flip can "GET" . route) adminMenu
            mActiveMenuR = routeBestMatch mCurrentR $ map route am
            gravatarSize = 28 :: Int
            gOpts = def
                    { gSize = Just $ Size $ gravatarSize * 2 -- retina
                    }

        pc <- widgetToPageContent $ do
            addStylesheet $ coreR $ AdminStaticR $ CssAdminR NormalizeR
            addStylesheet $ coreR $ AdminStaticR $ CssAdminR BootstrapCssR
            addScript $ coreR $ AdminStaticR $ JsAdminR JQueryR
            addScript $ coreR $ AdminStaticR $ JsAdminR BootstrapJsR
            $(widgetFile "admin-layout")
        withUrlRenderer $(hamletFile "templates/admin-layout-wrapper.hamlet")

    adminAuthLayout :: WidgetT master IO () -> HandlerT master IO Html
    adminAuthLayout widget = do
        mmsg <- getMessage
        logoRowId <- newIdent

        pc <- widgetToPageContent $ do
            addStylesheet $ coreR $ AdminStaticR $ CssAdminR NormalizeR
            addStylesheet $ coreR $ AdminStaticR $ CssAdminR BootstrapCssR
            addScript $ coreR $ AdminStaticR $ JsAdminR JQueryR
            addScript $ coreR $ AdminStaticR $ JsAdminR BootstrapJsR
            $(widgetFile "admin-auth-layout")
        withUrlRenderer $(hamletFile "templates/admin-auth-layout-wrapper.hamlet")

    authLogoR :: Route master
    authLogoR = coreR $ AdminStaticR $ ImageAdminR LambdaCmsLogoR
    -- | A list of menu items to show in the backend.
    -- Each site is different so what goes in the list should be provided by the Base app.
    --
    -- @
    -- [ MenuItem (SomeMessage MsgUser)    (UserAdminOverciewR)    "user"
    -- , MenuItem (SomeMessage MsgProduct) (ProductAdminOverviewR) "shopping-cart" ]
    -- @
    adminMenu :: [AdminMenuItem master]
    adminMenu = []

    -- | Renders a Core Message.
    renderCoreMessage :: master
                      -> [Text]
                      -> CoreMessage
                      -> Text
    renderCoreMessage m (lang:langs) = do
        case (lang `elem` (renderLanguages m), lang) of
            (True, "en") -> englishMessage
            (True, "nl") -> dutchMessage
            _ -> renderCoreMessage m langs
    renderCoreMessage _ _ = defaultMessage

    -- | A list of languages to render.
    renderLanguages :: master -> [Text]
    renderLanguages _ = ["en"]

    -- | A default way of sending email. See <https://github.com/lambdacms/lambdacms-core/blob/master/sending-emails.md github> for details.
    -- The default is to print it all to stdout.
    lambdaCmsSendMail :: Mail -> HandlerT master IO ()
    lambdaCmsSendMail (Mail from tos ccs bccs headers parts) =
        liftIO . putStrLn . unpack $ "MAIL"
            <> "\n  From: "        <> (address from)
            <> "\n  To: "          <> (maddress tos)
            <> "\n  Cc: "          <> (maddress ccs)
            <> "\n  Bcc: "         <> (maddress bccs)
            <> "\n  Subject: "     <> subject
            <> "\n  Attachment: "  <> attachment
            <> "\n  Plain body: "  <> plainBody
            <> "\n  Html body: "   <> htmlBody
        where
            subject = Data.Text.concat . map snd $ filter (\(k,_) -> k == "Subject") headers
            attachment :: Text
            attachment = intercalate ", " . catMaybes . map (partFilename) $ concatMap (filter (isJust . partFilename)) parts
            htmlBody = getFromParts "text/html; charset=utf-8"
            plainBody = getFromParts "text/plain; charset=utf-8"
            getFromParts x = decodeUtf8 . LB.toStrict . LB.concat . map partContent $ concatMap (filter ((==) x . partType)) parts
            maddress = intercalate ", " . map (address)
            address (Address n e) = case n of
                                        Just n' -> n' <> " " <> e'
                                        Nothing -> e'
                where e' = "<" <> e <> ">"

getLambdaCmsAuthId :: LambdaCmsAdmin master => Creds master -> HandlerT master IO (Maybe (AuthId master))
getLambdaCmsAuthId creds = runDB $ do
    user <- getBy $ UniqueAuth (credsIdent creds) True
    case user of
        Just (Entity uid _) -> do
            timeNow <- liftIO getCurrentTime
            _ <- update uid [UserLastLogin =. Just timeNow]
            return $ Just uid
        Nothing -> return Nothing

lambdaCmsMaybeAuthId :: LambdaCmsAdmin master => HandlerT master IO (Maybe (AuthId master))
lambdaCmsMaybeAuthId = do
    mauthId <- defaultMaybeAuthId
    maybe (return Nothing) maybeActiveAuthId mauthId
    where
        maybeActiveAuthId authId = do
            user <- runDB $ get404 authId
            return $ case userActive user of
                True -> Just authId
                False -> Nothing

-- | Checks whether a user is allowed perform an action and returns the route to that action if he is.
-- This way, users only see routes they're allowed to visit.
canFor :: LambdaCmsAdmin master
          => master                     -- Needed to make function injective.
          -> Maybe (Set (Roles master)) -- ^ Set of Roles the user has.
          -> Route master               -- ^ The action to perform.
          -> ByteString                 -- ^ The requested method (e/g: GET, POST, ...).
          -> Maybe (Route master)       -- ^ ust route when the user is allowed to perform the action, Nothing otherwise.
canFor m murs theRoute method = case isAuthorizedTo m murs $ actionAllowedFor theRoute method of
    Authorized -> Just theRoute
    _ -> Nothing

-- | A wrapper function that gets the roles of a user and calls 'canFor' with it.
-- This is what you'll use in a handler.
--
-- > can <- getCan
--
-- Then, in hamlet:
--
-- @
-- $maybe r <- can (SomeRouteR)
--   ... @{r}
-- @
getCan :: LambdaCmsAdmin master => HandlerT master IO (Route master -> ByteString -> Maybe (Route master))
getCan = do
    mauthId <- maybeAuthId
    murs <- forM mauthId getUserRoles
    y <- getYesod
    return $ canFor y murs

-- | A default admin menu.
defaultCoreAdminMenu :: LambdaCmsAdmin master => (Route CoreAdmin -> Route master) -> [AdminMenuItem master]
defaultCoreAdminMenu tp = [ MenuItem (SomeMessage Msg.MenuDashboard) (tp AdminHomeR) "home"
                          , MenuItem (SomeMessage Msg.MenuUsers) (tp $ UserAdminR UserAdminIndexR) "user"
                          ]

-- | Shorcut for rendering a subsite Widget in the admin layout.
adminLayoutSub :: LambdaCmsAdmin master
                  => WidgetT sub IO ()
                  -> HandlerT sub (HandlerT master IO) Html
adminLayoutSub widget = widgetToParentWidget widget >>= lift . adminLayout

-- | Extension for bootstrap (give a name to input field).
withName :: Text -> FieldSettings site -> FieldSettings site
withName name fs = fs { fsName = Just name }

withAttrs :: [(Text, Text)] -> FieldSettings site -> FieldSettings site
withAttrs attrs fs = fs { fsAttrs = attrs }

-- | Wrapper for humanReadableTimeI18N'. It uses Yesod's own i18n functionality.
lambdaCmsHumanTimeLocale :: LambdaCmsAdmin master => HandlerT master IO HumanTimeLocale
lambdaCmsHumanTimeLocale = do
    langs <- languages
    y <- getYesod
    let rm = unpack . renderMessage y langs
    return $ HumanTimeLocale
        { justNow       = rm Msg.TimeJustNow
        , secondsAgo    = rm . Msg.TimeSecondsAgo . pack
        , oneMinuteAgo  = rm Msg.TimeOneMinuteAgo
        , minutesAgo    = rm . Msg.TimeMinutesAgo . pack
        , oneHourAgo    = rm Msg.TimeOneHourAgo
        , aboutHoursAgo = rm . Msg.TimeAboutHoursAgo . pack
        , at            = (\_ x -> rm $ Msg.TimeAt $ pack x)
        , daysAgo       = rm . Msg.TimeDaysAgo . pack
        , weekAgo       = rm . Msg.TimeWeekAgo . pack
        , weeksAgo      = rm . Msg.TimeWeeksAgo . pack
        , onYear        = rm . Msg.TimeOnYear . pack
        , locale        = lambdaCmsTimeLocale langs
        , dayOfWeekFmt  = rm Msg.DayOfWeekFmt
        , thisYearFmt   = "%b %e"
        , prevYearFmt   = "%b %e, %Y"
        }

routeBestMatch :: RenderRoute master
                  => Maybe (Route master)
                  -> [Route master]
                  -> Maybe (Route master)
routeBestMatch (Just cr) rs = fmap snd $ find cmp orrs
    where
        (cparts, _) = renderRoute cr
        rrs = map ((fst . renderRoute) &&& id) rs
        orrs = reverse $ sortBy (comparing (length . fst)) rrs
        cmp (route', _) = route' == (take (length route') cparts)
routeBestMatch _ _ = Nothing

class LambdaCmsLoggable entity where
    logMessage :: LambdaCmsAdmin master => master -> ByteString -> entity -> Maybe (SomeMessage master)
    logRoute :: LambdaCmsAdmin master => master -> Key entity -> Maybe (Route master)

instance LambdaCmsLoggable User where
    logMessage _ "POST"       = jsm Msg.LogCreatedUser
    logMessage _ "PATCH"      = jsm Msg.LogUpdatedUser
    logMessage _ "DELETE"     = jsm Msg.LogDeletedUser
    logMessage _ "CHPASS"     = jsm Msg.LogChangedPasswordUser
    logMessage _ "RQPASS"     = jsm Msg.LogRequestedPasswordUser
    logMessage _ "DEACTIVATE" = jsm Msg.LogDeactivatedUser
    logMessage _ "ACTIVATE"   = jsm Msg.LogActivatedUser
    logMessage _ _            = const Nothing

    logRoute _ userId = Just . coreR . UserAdminR $ UserAdminEditR userId

jsm :: forall b master. RenderMessage master b => (Text -> b) -> User -> Maybe (SomeMessage master)
jsm msg = Just . SomeMessage . msg . userName

logAction :: (LambdaCmsAdmin master, LambdaCmsLoggable entity) => Entity entity -> HandlerT master IO ()
logAction (Entity objectId object') = do
    wai <- waiRequest
    y <- getYesod
    authId <- requireAuthId
    timeNow <- liftIO getCurrentTime
    ident <- liftIO generateUUID

    let method = requestMethod wai
        langs = renderLanguages y
        mRoute = logRoute y objectId
        mPath = T.intercalate "/" . fst . renderRoute <$> mRoute

    mapM_ (saveLog y ident method timeNow object' mPath authId) langs
    where
        saveLog y ident method time entity mPath userId lang = case logMessage y method entity of
            Just message' -> do
                let message = renderMessage y [lang] message'
                runDB . insert_ $ ActionLog
                                  { actionLogIdent = ident
                                  , actionLogUserId = userId
                                  , actionLogMessage = message
                                  , actionLogLang = lang
                                  , actionLogPath = mPath
                                  , actionLogCreatedAt = time
                                  }
            Nothing -> return ()
