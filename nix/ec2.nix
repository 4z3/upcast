# Configuration specific to the EC2/Nova/Eucalyptus backend.

{ config, pkgs, utils, lib ? pkgs.lib, ... }:

with utils;
with lib;

let
  cfg = config.deployment.ec2;

  inherit (import ./lib.nix { inherit config pkgs utils lib; }) union resource;

  defaultEbsOptimized =
    let props = config.deployment.ec2.physicalProperties;
    in if props == null then false else (props.allowsEbsOptimized or false);

    ec2DiskOptions = { config, ... }: {
      options = {
        disk = mkOption {
          default = "";
          example = "vol-d04895b8";
          type = union types.str (resource "ebs-volume");
          apply = x: if builtins.isString x then x else "res-" + x._name;
          description = ''
            EC2 identifier of the disk to be mounted.  This can be an
            ephemeral disk (e.g. <literal>ephemeral0</literal>), a
            snapshot ID (e.g. <literal>snap-1cbda474</literal>) or a
            volume ID (e.g. <literal>vol-d04895b8</literal>).  Leave
            empty to create an EBS volume automatically.  It can also be
            an EBS resource (e.g. <literal>resources.ebsVolumes.big-disk</literal>).
            '';
        };

        blockDeviceMappingName = mkOption {
          default = "";
          type = types.str;
          example = "/dev/sdb";
          description = ''
            The name of the block device that's accepted by AWS' RunInstances.
            Must properly map to <literal>fileSystems.device</literal> option.
            Leave blank for defaults.
          '';
        };

        fsType = mkOption {
          default = "ext4"; # FIXME: this default doesn't work
          type = types.str;
          description = ''
            Filesystem type for automatically created EBS volumes.
          '';
        };
      };
    };

  isEc2Hvm =
      cfg.instanceType == "cc1.4xlarge"
   || cfg.instanceType == "cc2.8xlarge"
   || cfg.instanceType == "hs1.8xlarge"
   || cfg.instanceType == "cr1.8xlarge"
   || builtins.substring 0 2 cfg.instanceType == "i2"
   || builtins.substring 0 2 cfg.instanceType == "c3"
   || builtins.substring 0 2 cfg.instanceType == "r3"
   || builtins.substring 0 2 cfg.instanceType == "m3"
   || builtins.substring 0 2 cfg.instanceType == "t2";

  resolveDevice = base: override: dmToDevice (if override == "" then base else override);

  # Map "/dev/mapper/xvdX" to "/dev/xvdX".
  dmToDevice = dev:
    if builtins.substring 0 12 dev == "/dev/mapper/"
    then "/dev/" + builtins.substring 12 100 dev
    else dev;

  amis = import ./ec2-amis.nix;
in
{
  options = {

    deployment.ec2.accessKeyId = mkOption {
      default = "";
      example = "AKIAIEMEJZVMPOHZWKZQ";
      type = types.str;
      description = ''
        This option is (yet) ignored by Upcast.
      '';
    };

    deployment.ec2.region = mkOption {
      default = "";
      example = "us-east-1";
      type = types.str;
      description = ''
        Amazon EC2 region in which the instance is to be deployed.
        This option only applies when using EC2.  It implicitly sets
        <option>deployment.ec2.ami</option>.
      '';
    };

    deployment.ec2.zone = mkOption {
      default = "";
      example = "us-east-1c";
      type = types.str;
      description = ''
        The EC2 availability zone in which the instance should be
        created.  If not specified, a zone is selected automatically.
      '';
    };

    deployment.ec2.ami = mkOption {
      example = "ami-ecb49e98";
      type = types.str;
      description = ''
        EC2 identifier of the AMI disk image used in the virtual
        machine.  This must be a NixOS image providing SSH access.
      '';
    };

    deployment.ec2.ebsBoot = mkOption {
      default = true;
      type = types.bool;
      description = ''
        Whether you want to boot from an EBS-backed AMI.  Only
        EBS-backed instances can be stopped and restarted, and attach
        other EBS volumes at boot time.  This option determines the
        selection of the default AMI; if you explicitly specify
        <option>deployment.ec2.ami</option>, it has no effect.
      '';
    };

    deployment.ec2.instanceType = mkOption {
      default = "m1.small";
      example = "m1.large";
      type = types.str;
      description = ''
        EC2 instance type.  See <link
        xlink:href='http://aws.amazon.com/ec2/instance-types/'/> for a
        list of valid Amazon EC2 instance types.
      '';
    };

    deployment.ec2.instanceProfileARN = mkOption {
      default = "";
      example = "arn:aws:iam::123456789012:instance-profile/S3-Permissions";
      type = types.str;
      description = ''
        The ARN of the IAM Instance Profile (IIP) to associate with
        the instances.
      '';
    };

    deployment.ec2.keyPair = mkOption {
      example = "my-keypair";
      type = union types.str (resource "ec2-keypair");
      apply = x: if builtins.isString x then x else x.name;
      description = ''
        Name of the SSH key pair to be used to communicate securely
        with the instance.  Key pairs can be created using the
        <command>ec2-add-keypair</command> command.
      '';
    };

    deployment.ec2.securityGroups = mkOption {
      default = [ "default" ];
      example = [ "my-group" "my-other-group" ];
      type = types.listOf (union types.str (resource "ec2-security-group"));
      apply = map (x: if builtins.isString x then x else x._name);
      description = ''
        Security groups for the instance.  These determine the
        firewall rules applied to the instance.
      '';
    };

    deployment.ec2.blockDeviceMapping = mkOption {
      default = { };
      example = { "/dev/xvdb".disk = "ephemeral0"; "/dev/xvdg".disk = "vol-d04895b8"; };
      type = types.attrsOf types.optionSet;
      options = ec2DiskOptions;
      description = ''
        Block device mapping.  <filename>/dev/xvd[a-e]</filename> must be ephemeral devices.
      '';
    };

    deployment.ec2.physicalProperties = mkOption {
      default = {};
      example = { cores = 4; memory = 14985; };
      description = ''
        Attribute set containing number of CPUs and memory available to
        the machine.
      '';
    };

    deployment.ec2.ebsOptimized = mkOption {
      default = defaultEbsOptimized;
      type = types.bool;
      description = ''
        Whether the EC2 instance should be created as an EBS Optimized instance.
        (Requires you to pick a proper instanceType)
      '';
    };

    deployment.ec2.subnet = mkOption {
      type = types.nullOr (union types.str (resource "ec2-subnet"));
      default = null;
      apply = x: if x == null then null else if builtins.isString x then x else x._name;
      description = ''
        EC2 VPC subnet id
      '';
    };

    deployment.ec2.userData = mkOption {
      default = {};
      type = types.attrsOf types.path;
      example = { host-aes-key = "./secrets/aes-key"; };
      description = ''
        Attribute set containing mappings to files that will be passed in as user data.
      '';
    };

    fileSystems = mkOption {
      options = {
        ec2 = mkOption {
          default = null;
          type = types.uniq (types.nullOr types.optionSet);
          options = ec2DiskOptions;
          description = ''
            EC2 disk to be attached to this mount point.  This is
            shorthand for defining a separate
            <option>deployment.ec2.blockDeviceMapping</option>
            attribute.
          '';
        };
      };
    };

  };

  config = {
    nixpkgs.system = mkOverride 900 "x86_64-linux";

    boot.loader.grub.extraPerEntryConfig = mkIf isEc2Hvm ( mkOverride 10 "root (hd0,0)" );

    deployment.ec2.ami = mkDefault (
      let
        type = if isEc2Hvm then "hvm" else if cfg.ebsBoot then "ebs" else "s3";
      in
        with builtins;
        if hasAttr cfg.region amis then
          let r = getAttr cfg.region amis;
          in if hasAttr type r then getAttr type r else ""
        else
          # !!! Doesn't work, not lazy enough.
          #throw "I don't know an AMI for region ‘${cfg.region}’ and platform type ‘${config.nixpkgs.system}’"
          ""
      );

    # Workaround: the evaluation of blockDeviceMapping requires fileSystems to be defined.
    fileSystems = {};

    deployment.ec2.blockDeviceMapping = mkFixStrictness (listToAttrs
      (map (fs: nameValuePair (resolveDevice fs.device fs.ec2.blockDeviceMappingName)
        { inherit (fs.ec2) disk;
          fsType = if fs.fsType != "auto" then fs.fsType else fs.ec2.fsType;
        })
       (filter (fs: fs.ec2 != null) (attrValues config.fileSystems))));

    deployment.ec2.physicalProperties =
      let
        type = config.deployment.ec2.instanceType or "unknown";
        mapping = {
          "t1.micro"    = { cores = 1;  memory = 595;    allowsEbsOptimized = false; };
          "m1.small"    = { cores = 1;  memory = 1658;   allowsEbsOptimized = false; };
          "m1.medium"   = { cores = 1;  memory = 3755;   allowsEbsOptimized = false; };
          "m1.large"    = { cores = 2;  memory = 7455;   allowsEbsOptimized = true;  };
          "m1.xlarge"   = { cores = 4;  memory = 14985;  allowsEbsOptimized = true;  };
          "m2.xlarge"   = { cores = 2;  memory = 17084;  allowsEbsOptimized = false; };
          "m2.2xlarge"  = { cores = 4;  memory = 34241;  allowsEbsOptimized = true;  };
          "m2.4xlarge"  = { cores = 8;  memory = 68557;  allowsEbsOptimized = true;  };
          "m3.xlarge"   = { cores = 4;  memory = 14985;  allowsEbsOptimized = true;  };
          "m3.2xlarge"  = { cores = 8;  memory = 30044;  allowsEbsOptimized = true;  };
          "c1.medium"   = { cores = 2;  memory = 1697;   allowsEbsOptimized = false; };
          "c1.xlarge"   = { cores = 8;  memory = 6953;   allowsEbsOptimized = true;  };
          "cc1.4xlarge" = { cores = 16; memory = 21542;  allowsEbsOptimized = false; };
          "cc2.8xlarge" = { cores = 32; memory = 59930;  allowsEbsOptimized = false; };
          "hi1.4xlarge" = { cores = 16; memory = 60711;  allowsEbsOptimized = false; };
          "cr1.8xlarge" = { cores = 32; memory = 245756; allowsEbsOptimized = false; };
        };
      in attrByPath [ type ] null mapping;
  };
}
