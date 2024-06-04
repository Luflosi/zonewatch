# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

{ config, lib, pkgs, ... }:

let
  cfg = config.services.zonewatch;
  settingsFormat = pkgs.formats.toml { };

  zoneOpts = { lib, name, ... }: {
    options = {
      dir = lib.mkOption {
        type = lib.types.path;
        example = "/var/lib/zonewatch/";
        description = lib.mdDoc ''
          Path to where the zone file should be generated.
        '';
      };
      reload_program_args = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        example = [ "reload" "example.org" ];
        description = lib.mdDoc ''
          Command line arguments to be passed to the reload command.
        '';
      };
      ttl = lib.mkOption {
        type = lib.types.str;
        default = "1d";
        description = lib.mdDoc ''
          The default TTL for the generated zone file.
        '';
      };
      includes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        example = [ "/path/to/file 1.zone" "/path/to/file 2.zone" ];
        description = lib.mdDoc ''
          Absolute paths or paths relative to the corresponding zone file.
          These are included in the generated zone file with the $INCLUDE directive.
        '';
      };
      soa = lib.mkOption {
        type = lib.types.submodule soaOpts;
        default = {};
        description = lib.mdDoc ''
          Attribute set of SOA options.
          Note that the name of minimum is actually misleading due to historical reasons. Instead it is the negative response caching TTL.
        '';
        example = {
          soa = {
            ttl = "1d";
            mname = "ns1.example.org.";
            rname = "john\\.doe.example.org.";
            refresh = "1d";
            retry = "2h";
            expire = "1000h";
            minimum = "1h";
          };
        };
      };
    };
  };

  soaOpts = { lib, name, ... }: {
    options = {
      ttl = lib.mkOption {
        type = lib.types.str;
        default = "1d";
        description = lib.mdDoc ''
          The TTL of the SOA DNS record.
        '';
      };
      mname = lib.mkOption {
        type = lib.types.str;
        example = "ns1.example.org.";
        description = lib.mdDoc ''
          The primary master name server for this zone.
        '';
      };
      rname = lib.mkOption {
        type = lib.types.str;
        example = "john\\.doe.example.org.";
        description = lib.mdDoc ''
          Email address of the administrator responsible for this zone.
          Not that there is no @ symbol. Instead a different syntax is used.
        '';
      };
      refresh = lib.mkOption {
        type = lib.types.str;
        default = "1d";
        description = lib.mdDoc ''
          Number of seconds after which secondary name servers should query the master for the SOA record, to detect zone changes.
          You should configure your primary DNS server to actively notify your secondary nameservers of changes, so you don't need to wait this long.
        '';
      };
      retry = lib.mkOption {
        type = lib.types.str;
        default = "2h";
        description = lib.mdDoc ''
          Number of seconds after which secondary name servers should retry to request the serial number from the master if the master does not respond.
          It must be less than refresh.
        '';
      };
      expire = lib.mkOption {
        type = lib.types.str;
        default = "1000h";
        description = lib.mdDoc ''
          Number of seconds after which secondary name servers should stop answering requests for this zone if the master does not respond.
          This value must be bigger than the sum of refresh and retry.
        '';
      };
      minimum = lib.mkOption {
        type = lib.types.str;
        default = "1h";
        description = lib.mdDoc ''
          Used in calculating the time to live for purposes of negative caching.
          Authoritative name servers take the smaller of the SOA TTL and the SOA MINIMUM to send as the SOA TTL in negative responses.
        '';
      };
    };
  };

in
{
  options = {
    services.zonewatch = {
      enable = lib.mkEnableOption (lib.mdDoc "the DynDNS server");

      settings = {
        db = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/zonewatch/db.sqlite";
          example = "/some/other/dir/db.sqlite";
          description = lib.mdDoc ''
            Where the SQLite database should be stored.
          '';
        };
        reload_program_bin = lib.mkOption {
          type = lib.types.path;
          default = "${pkgs.coreutils}/bin/false";
          example = lib.literalExpression ''"''${pkgs.dig.dnsutils}/bin/rndc"'';
          description = lib.mdDoc ''
            Path to a program which is used to tell the DNS server to reload the zone file.
            This program is called after every time the zone file is rewritten.
          '';
        };

        zones = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule zoneOpts);
          default = {};
          description = lib.mdDoc "Attribute set of zones.";
          example = {
            "example.org" = {
              path = "/var/lib/zonewatch/example.org.zone";
              reload_program_args = [ "reload" "example.org" ];
              ttl = "1d";
              includes = [ "file 1.zone" "file 2.zone" ];
              soa = {
                ttl = "1d";
                mname = "ns1.example.org.";
                rname = "john\\.doe.example.org.";
                refresh = "1d";
                retry = "2h";
                expire = "1000h";
                minimum = "1h";
              };
            };
          };
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.packages = [ pkgs.zonewatch ];

    systemd.services.zonewatch = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = let
        settingsFile = settingsFormat.generate "zonewatch.toml" cfg.settings;
      in {
        ExecStart = [ "" "${pkgs.zonewatch}/bin/zonewatch --config '${settingsFile}'" ];
      };
    };
  };
}
