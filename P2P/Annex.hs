{- P2P protocol, Annex implementation
 -
 - Copyright 2016 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE RankNTypes, FlexibleContexts #-}

module P2P.Annex
	( RunMode(..)
	, RunEnv(..)
	, runFullProto
	) where

import Annex.Common
import Annex.Content
import P2P.Protocol
import P2P.IO
import Logs.Location
import Types.NumCopies

import Control.Monad.Free
import qualified Data.ByteString.Lazy as L

-- When we're serving a peer, we know their uuid, and can use it to update
-- transfer logs.
data RunMode
	= Serving UUID
	| Client

-- Full interpreter for Proto, that can receive and send objects.
runFullProto :: RunMode -> RunEnv -> Proto a -> Annex (Maybe a)
runFullProto runmode runenv = go
  where
	go :: RunProto Annex
	go (Pure v) = pure (Just v)
	go (Free (Net n)) = runNet runenv go n
	go (Free (Local l)) = runLocal runmode go l

runLocal :: RunMode -> RunProto Annex -> LocalF (Proto a) -> Annex (Maybe a)
runLocal runmode runner a = case a of
	TmpContentSize k next -> do
		tmp <- fromRepo $ gitAnnexTmpObjectLocation k
		size <- liftIO $ catchDefaultIO 0 $ getFileSize tmp
		runner (next (Len size))
	ContentSize k next -> do
		let getsize = liftIO . catchMaybeIO . getFileSize
		size <- inAnnex' isJust Nothing getsize k
		runner (next (Len <$> size))
	-- TODO transfer logs
	ReadContent k (Offset o) next -> do
		v <- tryNonAsync $ prepSendAnnex k
		case v of
			-- The check can detect a problem after the
			-- content is sent, but we don't use it.
			-- Instead, the receiving peer must AlwaysVerify
			-- the content it receives.
			Right (Just (f, _check)) -> do
				v' <- liftIO $ tryNonAsync $ do
					h <- openBinaryFile f ReadMode
					when (o /= 0) $
						hSeek h AbsoluteSeek o
					L.hGetContents h
				case v' of
					Left _ -> return Nothing
					Right b -> runner (next b)
			_ -> return Nothing
	-- TODO transfer logs
	WriteContent k (Offset o) (Len l) b next -> do
		ok <- flip catchNonAsync (const $ return False) $
			getViaTmp AlwaysVerify k $ \tmp -> liftIO $ do
				withBinaryFile tmp WriteMode $ \h -> do
					when (o /= 0) $
						hSeek h AbsoluteSeek o
					L.hPut h b
				sz <- getFileSize tmp
				return (toInteger sz == l, UnVerified)
		runner (next ok)
	SetPresent k u next -> do
		v <- tryNonAsync $ logChange k u InfoPresent
		case v of
			Left _ -> return Nothing
			Right () -> runner next
	CheckContentPresent k next -> do
		v <- tryNonAsync $ inAnnex k
		case v of
			Left _ -> return Nothing
			Right result -> runner (next result)
	RemoveContent k next -> do
		v <- tryNonAsync $ lockContentForRemoval k $ \contentlock -> do
				removeAnnex contentlock
				logStatus k InfoMissing
				return True
		case v of
			Left _ -> return Nothing
			Right result -> runner (next result)
	TryLockContent k protoaction next -> do
		v <- tryNonAsync $ lockContentShared k $ \verifiedcopy -> 
			case verifiedcopy of
				LockedCopy _ -> runner (protoaction True)
				_ -> runner (protoaction False)
		-- If locking fails, lockContentShared throws an exception.
		-- Let the peer know it failed.
		case v of
			Left _ -> runner $ do
				protoaction False
				next
			Right _ -> runner next