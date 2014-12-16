


```
                           ,                     _
                          /   _, _   /  _/ _,   / ) _  _,
                         (__ (/ //) () (/ (/   (__ //)_)

                   developer friendly :: type safe :: performant
```


# Rationale

LambdaCms is a bunch of packaged libraries that contain sub-sites for the
[Yesod application framework](http://www.yesodweb.com).  The LambdaCms
sub-sites can be composed to quickly develop a performant website with
content management functionality.

The `lambdacms-*` packages each provide some specific behavior and can in
turn depend on eachother.  The only mandatory package is `lambdacms-core`
(this package), it provides functionality that all other `lambdacms-*` packages
may rely on.

Each `lambdacms-*` package contains a sub-site.  To use these sub-sites we
need to create a standard Yesod application, which we will refer to as the
"base application".
It is in this base app that the LambdaCms sub-sites can be installed,
which is as simple as adding the packages as dependencies to the base app's
`.cabal` file and writing some glue code (as explained below).

In the base app we have to:
* organize the main menu of the admin backend,
* configure a the database connection,
* specify the authentication strategies, and
* define admin user roles and their permissions.

In the base app we may also:
* override default behavior,
* override UI texts,
* provide a means to send email notifications, and
* last but not least, write the themes so the website can actually be
  visited (recommended).


# Getting started

We about to start a project named `YourApp`. For a real project you obviously
want to substitute a more descriptive name.  For testing things out you may
want to keep this name as you enjoy the convenience of copy-pasting the
instructions that follow.


### The tool chain

Make sure to have **GHC** 7.8.3+, **cabal-install** 1.20+, **happy**, **alex**
and **yesod-bin** 1.4.1+ installed, and their binaries available to your
shell's `$PATH`.

To check that you are good to go, you can use these commands.

    ghc -V
    cabal -V
    happy -V
    alex -V
    yesod version

In case you are not good to go, you may want to follow the
[installation guide on the Stackage website](http://www.stackage.org/install)
which provides instructions for all dependencies but `yesod-bin`
for a variety of platforms.

Once you meet all the requirements except for `yesod-bin`, instal it.

    cabal install "yesod-bin >= 1.4.1"


### Create the base application

With the following command you create a "scaffolded" Yesod application.
The command is interactive, you need to supply some configuration values,
pick your database of choice, and name it `YourApp` if you want follow this
guide closely.

    yesod init

After scaffolding move into the project folder.

    cd YourApp

If you have chosen a database other then Sqlite: create a database and a
user with the right permissions for your specific database, and supply the
credentials to the `config/setting.yml` file.


### Specify a Stackage snapshot

To avoid spending too much time on build issues we recomend to make use
of the "Stackage LTS 0" snapshots. The developers of LambdaCms also
make use of these snapshots, which should leave little room for
build issues.  In case you are using "LTS 0" and experience problems
during builds, we consider this a bug, please
[raise an issue](https://github.com/lambdacms/lambdacms-core/issues).

To make use of "LTS 0" run the following commands from within your
project folder.

    wget http://www.stackage.org/lts/0/cabal.config
    cabal update
    cabal install

The following commands will build your Yesod application and run it in
development mode.

    cabal install --enable-tests . --max-backjumps=-1 --reorder-goals
    yesod devel

Now test it by pointing the browser to `localhost:3000`.

If all went well you are ready to add LambdaCms to your app.


### Add LambdaCms

At some point the `lambdacms-core` package will be distributed from Hackage.
Currently this is not the case so we install it from Github.

    cd ..
    git clone git@github.com:lambdacms/lambdacms-core.git
    cd lambdacms-core
    cabal install
    cd ../YourApp

In the following sub-sections we explain how to install `lambdacms-core` into
the base application.  Much of what we show here can be accomplished in
many different ways, what we provide here is merely to get you started.


#### Modify the `.cabal` file (name depends on the name of your project)

Add to the `build-depends` section:

```
, lambdacms-core                >= 0.0.7      && < 0.1
, wai                           >= 3.0.2      && < 3.1
```

Add to `library/exposed-modules` section:

```
Roles
```

#### Modify the `config/routes` file

Add the following routes:

```
/admin/auth    AuthR                 Auth        getAuth
/admin/core    CoreAdminR            CoreAdmin   getLambdaCms
/admin         AdminHomeRedirectR    GET
```

#### Modify the `config/settings.yml` file

Add the following line, which sets the email address for an admin user account
that is created (and activated) in case no admin user exists.

```
admin: <your email address>
```

#### Modify the `Settings.hs` file

Append the following record to the `AppSettings` data type:

```haskell
    , appAdmin                  :: Text
```

Add this line to `instance FromJSON AppSettings`:
Make sure you do this in the same order as properties appear in `settings.yml`.

```haskell
        appAdmin                  <- o .: "admin"
```

#### Modify the `config/models` file

Replace **all** of the file's contant with the following `UserRole` definition:

```
UserRole
    userId UserId
    roleName RoleName
    UniqueUserRole userId roleName
    deriving Typeable Show
```

#### Modify the `Models.hs` file

Add the following imports:

```haskell
import Roles
import LambdaCms.Core
```

#### Modify the `Application.hs` file

Add the following imports:

```haskell
import LambdaCms.Core
import LambdaCms.Core.Settings (generateUUID)
import qualified Network.Wai.Middleware.MethodOverridePost as MiddlewareMOP
```

Add the following function:

```haskell
getAdminHomeRedirectR :: Handler Html
getAdminHomeRedirectR = do
    redirect $ CoreAdminR AdminHomeR
```

Replace the `makeFoundation` function with the following code, so it will
create the `admin` user as provided in `settings.yml` and run all needed migrations:

```haskell
makeFoundation :: AppSettings -> IO App
makeFoundation appSettings' = do
    -- Some basic initializations: HTTP connection manager, logger, and static
    -- subsite.
    appHttpManager' <- newManager
    appLogger' <- newStdoutLoggerSet defaultBufSize >>= makeYesodLogger
    appStatic' <-
        (if appMutableStatic appSettings' then staticDevel else static)
        (appStaticDir appSettings')

    -- We need a log function to create a connection pool. We need a connection
    -- pool to create our foundation. And we need our foundation to get a
    -- logging function. To get out of this loop, we initially create a
    -- temporary foundation without a real connection pool, get a log function
    -- from there, and then create the real foundation.
    let mkFoundation appConnPool' = App { appSettings    = appSettings'
                                        , appStatic      = appStatic'
                                        , appHttpManager = appHttpManager'
                                        , appLogger      = appLogger'
                                        , appConnPool    = appConnPool'
                                        , getLambdaCms   = CoreAdmin
                                        }
        tempFoundation = mkFoundation $ error "connPool forced in tempFoundation"
        logFunc = messageLoggerSource tempFoundation appLogger'

    -- Create the database connection pool
    pool <- flip runLoggingT logFunc $ createPostgresqlPool
        (pgConnStr  $ appDatabaseConf appSettings')
        (pgPoolSize $ appDatabaseConf appSettings')

    let theFoundation = mkFoundation pool
    runLoggingT
        (runSqlPool (mapM_ runMigration [migrateAll, migrateLambdaCmsCore]) pool)
        (messageLoggerSource theFoundation appLogger')

    let admin = appAdmin appSettings'
    madmin <- runSqlPool (getBy (UniqueEmail admin)) pool
    case madmin of
        Nothing -> do
            timeNow <- getCurrentTime
            uuid <- generateUUID
            flip runSqlPool pool $
                insert_ User { userIdent     = uuid
                             , userPassword  = Nothing
                             , userName      = takeWhile (/= '@') admin
                             , userEmail     = admin
                             , userToken     = Nothing
                             , userCreatedAt = timeNow
                             , userLastLogin = Nothing
                             }
        _ -> return ()

    return theFoundation
```

In the function `makeApplication` replace this line:

```haskell
    return $ logWare $ defaultMiddlewaresNoLogging appPlain
```

With this line, adding a WAI middleware needed to make RESTful forms work
on older browsers:

```haskell
    return $ logWare $ MiddlewareMOP.methodOverridePost appPlain
```

## Create the `Roles.hs` file

Add the following content to it:

```haskell
module Roles where

import ClassyPrelude.Yesod

data RoleName = Admin
              | SuperUser
              | Blogger
              | MediaManager
              deriving (Eq, Ord, Show, Read, Enum, Bounded)

derivePersistField "RoleName"
```

## Modify the `Foundation.hs` file

Add the following imports:

```haskell
import qualified Data.Set                    as S
import qualified Network.Wai                 as W
import LambdaCms.Core
import Roles
```

Append the following record to the `App` data type:

```haskell
    , getLambdaCms   :: CoreAdmin
```

Change the implementation of `isAuthorized` (in `instance Yesod App`) to the
following, which allows fine-grained authorization based on `UserRoles`:

```haskell
isAuthorized theRoute _ = do
    mauthId <- maybeAuthId
    wai <- waiRequest
    y <- getYesod
    murs <- mapM getUserRoles mauthId
    return $ isAuthorizedTo y murs $ actionAllowedFor theRoute (W.requestMethod wai)
```

Change the implementation of `getAuthId` (in `instance YesodAuth App`) to:

```haskell
    getAuthId creds = do
        timeNow <- lift getCurrentTime
        runDB $ do
            x <- getBy $ UniqueEmail $ credsIdent creds
            case x of
                Just (Entity uid _) -> do
                    _ <- update uid [UserLastLogin =. Just timeNow] -- update last login time during the login process
                    return $ Just uid
                Nothing -> return Nothing
```

In `instance YesodAuth App` replace:

```haskell
    loginDest _ = HomeR
    logoutDest _ = HomeR
```

With:

```haskell
    loginDest _ = CoreAdminR AdminHomeR
    logoutDest _ = AuthR LoginR
```

Add the following instance to allow `Unauthenticated` `GET` requests for the
`HomeR` route (likely to be `/`) and other common routes such as `/robots.txt`.
The last pattern forbids access to any unspecified routes.
It is in `actionAllowedFor` that you will setup permissions for the roles.

```haskell
instance LambdaCmsAdmin App where
    type Roles App = RoleName

    actionAllowedFor (FaviconR) "GET" = Unauthenticated
    actionAllowedFor (RobotsR)  "GET" = Unauthenticated
    actionAllowedFor (HomeR)    "GET" = Unauthenticated
    actionAllowedFor (AuthR _)  _     = Unauthenticated
    actionAllowedFor _          _     = Nobody -- allow no one by default.

    coreR = CoreAdminR
    authR = AuthR
    masterHomeR = HomeR

    getUserRoles userId = do
        v <- runDB $ selectList [UserRoleUserId ==. userId] []
        return . S.fromList $ map (userRoleRoleName . entityVal) v

    setUserRoles userId rs = runDB $ do
        deleteWhere [UserRoleUserId ==. userId]
        mapM_ (insert_ . UserRole userId) $ S.toList rs

    adminMenu =  (defaultCoreAdminMenu CoreAdminR)
    renderLanguages _ = ["en", "nl"]
```

---

---

## Other Packages
Not every package is included in the stackage. These packages will be listed here.

Clone the repo, cd into it and simply run `cabal install`.

Listing of other packages:

* [friendly-time](https://github.com/pbrisbin/friendly-time)

# Links of interest

Obviously the [Yesod book](http://www.yesodweb.com/book) is a must read,
beyond that docs may sometimes be scarse.
Therefore this collection of links that may shed some light on corners of Yesod
that are of particular interest when hacking on LambdaCms.

http://stackoverflow.com/questions/13055611/what-should-the-type-be-for-a-subsite-widget-that-can-be-used-in-a-master-site

http://www.yesodweb.com/book/wiki-chat-example

https://github.com/yesodweb/yesod/tree/master/yesod-auth (probably the most complex subsite example)

https://groups.google.com/forum/#!searchin/yesodweb/persistent$20subsite/yesodweb/r3hf3xKYAmg/dJDPirX-q2MJ

https://github.com/piyush-kurur/yesod-admin (he stopped working on it before the subsite rewrite)
