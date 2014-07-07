{-# LANGUAGE TypeFamilies
           , MultiParamTypeClasses
           , FlexibleInstances
           , OverloadedStrings
           , TemplateHaskell
           #-}

-- boilerplate minimization for experimental stuff

module Aws.Ec2.TH (
  module Aws.Core
, module Aws.Ec2.Core
, module Aws.Ec2.Types
, ec2ValueTransactionDef
, ec2ValueTransaction
) where

import Language.Haskell.TH
import Language.Haskell.TH.Lib
import Language.Haskell.TH.Syntax

import Aws.Core
import Aws.Ec2.Core
import qualified Aws.Ec2.Core as EC2
import Aws.Ec2.Types

ec2ValueTransactionDef :: Name -> String -> String -> DecsQ
ec2ValueTransactionDef ty action tag = [d|
                  instance SignQuery $(conT ty) where
                      type ServiceConfiguration $(conT ty) = EC2Configuration
                      signQuery _ = ec2SignQuery [ ("Action", qArg $(stringE action))
                                                 , ("Version", qArg "2014-06-15")]

                  instance ResponseConsumer $(conT ty) Value where
                      type ResponseMetadata Value = EC2Metadata
                      responseConsumer _ = ec2ResponseConsumer $ valueConsumer $(stringE tag) id

                  instance Transaction $(conT ty) Value
                  |]

ec2ValueTransaction :: Name -> String -> DecsQ
ec2ValueTransaction ty tag = [d|
                  instance ResponseConsumer $(conT ty) Value where
                      type ResponseMetadata Value = EC2Metadata
                      responseConsumer _ = ec2ResponseConsumer $ valueConsumer $(stringE tag) id

                  instance Transaction $(conT ty) Value
                  |]