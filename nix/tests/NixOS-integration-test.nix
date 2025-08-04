# SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
# SPDX-License-Identifier: GPL-3.0-only

self:
{ lib, pkgs, ... }: {
  name = "zonewatch";
  nodes.machine = { config, pkgs, ... }: {
    imports = [
      self.outputs.nixosModules.zonewatch
      self.inputs.dyndnsd.nixosModules.dyndnsd
    ];

    systemd.services.create-bind-zones-dir = {
      description = "service that creates the directory where zonewatch writes its zone files";
      before = [ "zonewatch.service" "bind.service" ];
      requiredBy = [ "zonewatch.service" "bind.service" ];
      serviceConfig = {
        Type = "oneshot";
        Group = "named";
      };
      script = ''
        mkdir --verbose -p '/var/lib/bind/zones/'
        chmod 775 '/var/lib/bind/zones/'

        # Create an initial file for BIND to read
        # BIND complains if the zone file is initially empty but it seems to be fine
        (set -o noclobber;>'/var/lib/bind/zones/example.org.zone'||true) &>/dev/null
      '';
    };

    systemd.services.create-bind-dyn-dir = {
      description = "service that creates the directory where zonegen writes its zone files";
      requires = [ "create-bind-zones-dir.service" ];
      after = [ "create-bind-zones-dir.service" ];
      before = [ "zonewatch.service" "dyndnsd.service" "bind.service" ];
      requiredBy = [ "zonewatch.service" "dyndnsd.service" "bind.service" ];
      serviceConfig = {
        Type = "oneshot";
        Group = "zonegen";
      };
      script = ''
        mkdir --verbose -p '/var/lib/bind/zones/dyn/'
        chmod 775 '/var/lib/bind/zones/dyn/'

        # Create an initial file for zonewatch and BIND to read
        (set -o noclobber;>'/var/lib/bind/zones/dyn/example.org.zone'||true) &>/dev/null
      '';
    };

    # Check if we have write permission on the file itself,
    # and replace the file with a writable version if we don't.
    # This is unfortunately not atomic.
    # This could be avoided if the tempfile-fast rust crate allowed ignoring the ownership of the old file.
    systemd.services.dyndnsd.preStart = ''
      if ! [ -w '/var/lib/bind/zones/dyn/example.org.zone' ]; then
        # Copy the file, changing ownership
        cp '/var/lib/bind/zones/dyn/example.org.zone' '/var/lib/bind/zones/dyn/example.org.zone.tmp'
        # Replace the old file
        mv '/var/lib/bind/zones/dyn/example.org.zone.tmp' '/var/lib/bind/zones/dyn/example.org.zone'
      fi
    '';

    systemd.services.zonewatch.preStart = ''
      if ! [ -w '/var/lib/bind/zones/example.org.zone' ]; then
        # Copy the file, changing ownership
        cp '/var/lib/bind/zones/example.org.zone' '/var/lib/bind/zones/example.org.zone.tmp'
        # Replace the old file
        mv '/var/lib/bind/zones/example.org.zone.tmp' '/var/lib/bind/zones/example.org.zone'
      fi
    '';

    systemd.services.zonewatch = {
      after = [ "bind.service" ];
      wants = [ "bind.service" ];
      serviceConfig = {
        SupplementaryGroups = [ "named" ];
        ReadWritePaths = [ "/var/lib/bind/zones/" ];
        Environment = [ "RUST_LOG=zonewatch=trace" ];

        UMask = "0022"; # Allow all processes (including BIND) to read the zone files

        # Allow rndc to contact bind
        IPAddressAllow = [ "localhost" ];
        IPAddressDeny = "any";
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      };
    };

    # TODO: upstream the permission change into Nixpkgs
    systemd.tmpfiles.settings."create-ddns-key"."/etc/bind".d = {
      user = "named";
      group = "named";
    };
    systemd.services.create-ddns-key = {
      description = "Service to create a key for the named group to authenticate to BIND";
      before = [ "bind.service" "zonewatch.service" ];
      requiredBy = [ "bind.service" "zonewatch.service" ];
      script = ''
        if ! [ -f "/etc/bind/ddns.key" ]; then
          '${lib.getExe' pkgs.bind "rndc-confgen"}' -c /etc/bind/rndc.key -a -A hmac-sha256 2>/dev/null
          chmod 440 /etc/bind/rndc.key
        fi
      '';
      serviceConfig = {
        Type = "oneshot";
        StartLimitBurst = 1;
        User = "named";
        Group = "named";
        UMask = "0227";
      };
    };

    services.bind = {
      enable = true;
      forward = "only";
      forwarders = [];
      zones = {
        "example.org" = {
          file = "/var/lib/bind/zones/example.org.zone";
          master = true;
        };
      };
    };

    services.dyndnsd = {
      enable = true;
      useZonegen = true;
      settings = {
        users = {
          alice = {
            hash = "$argon2id$v=19$m=65536,t=3,p=1$ZFRHDlJOQ3UNQRN7em14R08FIRE$0SqSQRj45ZBz1MfCPq9DVMWt7VSl96m7XtW6maIcUB0";
            domains = {
              "example.org" = {
                ttl = 60;
                ipv6prefixlen = 48;
                ipv6suffix = "0:0:0:1::5";
              };
              "test.example.org" = {
                ttl = 300;
                ipv6prefixlen = 48;
                ipv6suffix = "0:0:0:1::6";
              };
            };
          };
        };
      };
    };

    services.zonewatch = {
      enable = true;
      settings = {
        reload_program_bin = lib.getExe' pkgs.dig.out "rndc";
        zones = {
          "example.org" = {
            dir = "/var/lib/bind/zones/";
            reload_program_args = [ "reload" "example.org" ];
            includes = let
              ns = pkgs.writeText "ns.example.org.zone" ''
                @  IN NS   ns.example.org.
                ns IN A    127.0.0.1
                ns IN AAAA ::1
              '';
            in [
              "${ns}"
              "/var/lib/bind/zones/dyn/example.org.zone"
            ];
            soa = {
              mname = "ns1.example.org.";
              rname = "john\\.doe.example.org.";
            };
          };
        };
      };
    };

    environment.systemPackages = [
      pkgs.dig.dnsutils # Make the `dig` command available in the test script
    ];
  };

  testScript = let
    curl-cmd = "sudo -u dyndnsd -g dyndnsd curl --fail-with-body -v --unix-socket /run/dyndnsd.sock";
  in ''
    def query(
        query: str,
        query_type: str,
        expected: str,
    ):
        """
        Execute a single query and and compare the result with expectation
        """
        out = machine.succeed(
            f"dig {query} {query_type} +short"
        ).strip()
        machine.log(f"DNS server replied with {out}")
        assert expected == out, f"Expected `{expected}` but got `{out}`"

    start_all()
    machine.wait_for_unit("bind.service")
    machine.wait_for_unit("zonewatch.service")
    machine.wait_until_succeeds("grep ' 1 ; serial' '/var/lib/bind/zones/example.org.zone'", timeout=30)
    machine.succeed("${curl-cmd} --fail-with-body -v 'http://[::1]:9841/update?user=alice&pass=123456&ipv4=2.3.4.5&ipv6=2:3:4:5:6:7:8:9'")
    # zonewatch waits a moment before it actually updates the file
    machine.wait_until_succeeds("grep ' 2 ; serial' '/var/lib/bind/zones/example.org.zone'", timeout=30)
    query("example.org", "A", "2.3.4.5")
    query("example.org", "AAAA", "2:3:4:1::5")
    query("test.example.org", "A", "2.3.4.5")
    query("test.example.org", "AAAA", "2:3:4:1::6")
  '';
}
