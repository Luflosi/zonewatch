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
      before = [ "zonewatch.service" ];
      requiredBy = [ "zonewatch.service" ];
      serviceConfig.Type = "oneshot";
      startLimitBurst = 1;
      script = ''
        mkdir --verbose -p '/var/lib/bind/zones/'
        chgrp named '/var/lib/bind/zones/'
        chmod 775 '/var/lib/bind/zones/'
        ls '/var/lib/bind/zones/'
        if ! [ -f "/var/lib/bind/zones/example.org.zone" ]; then
          # Create an initial file for BIND to read
          # BIND complains if the zone file is initially empty but it seems to be fine
          touch '/var/lib/bind/zones/example.org.zone'
        fi
      '';
    };

    users.groups.zonegen = {};
    systemd.services.create-bind-dyn-dir = {
      description = "service that creates the directory where zonegen writes its zone files";
      requires = [ "create-bind-zones-dir.service" ];
      after = [ "create-bind-zones-dir.service" ];
      before = [ "zonewatch.service" "dyndnsd.service" ];
      requiredBy = [ "zonewatch.service" "dyndnsd.service" ];
      serviceConfig.Type = "oneshot";
      startLimitBurst = 1;
      script = ''
        mkdir --verbose -p '/var/lib/bind/zones/dyn/'
        chgrp zonegen '/var/lib/bind/zones/dyn/'
        chmod 775 '/var/lib/bind/zones/dyn/'
        if ! [ -f "/var/lib/bind/zones/dyn/example.org.zone" ]; then
          # Create an initial file for zonewatch to read
          touch '/var/lib/bind/zones/dyn/example.org.zone'
        fi
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

    systemd.services.dyndnsd.serviceConfig = {
      SupplementaryGroups = [ "zonegen" ];
      ReadWritePaths = [ "/var/lib/bind/zones/dyn/" ];

      # The tempfile-fast rust crate tries to keep the old permissions, so we need to allow this class of system calls
      SystemCallFilter = [ "@chown" ];
      UMask = "0022"; # Allow all processes (including BIND and zonewatch) to read the zone files (and database)
    };

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
    systemd.services.bind.preStart = ''
      mkdir -m 0755 -p /etc/bind
      (umask 227 && ${pkgs.bind.out}/sbin/rndc-confgen -c /etc/bind/rndc.key -u named -a -A hmac-sha256 2>/dev/null)
      ls -la /etc/bind/rndc.key
      chgrp named /etc/bind/rndc.key
      chmod 440 /etc/bind/rndc.key
      ls -la /etc/bind/rndc.key
    '';

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
      settings = {
        update_program = {
          bin = "${pkgs.zonegen}/bin/zonegen";
          args = [ "--dir" "/var/lib/bind/zones/dyn/" ];
          initial_stdin = "drop\n";
          stdin_per_zone_update = "send\n";
          final_stdin = "quit\n";
          ipv4.stdin = "update add {domain}. {ttl} IN A {ipv4}\n";
          ipv6.stdin = "update add {domain}. {ttl} IN AAAA {ipv6}\n";
        };
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
        reload_program_bin = "${pkgs.dig.out}/bin/rndc";
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

  testScript = ''
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

    machine.start()
    machine.wait_for_unit("bind.service")
    machine.wait_for_unit("dyndnsd.service")
    machine.wait_for_unit("zonewatch.service")
    machine.wait_until_succeeds("grep ' 1 ; serial' '/var/lib/bind/zones/example.org.zone'", timeout=30)
    machine.succeed("curl --fail-with-body -v 'http://[::1]:9841/update?user=alice&pass=123456&ipv4=2.3.4.5&ipv6=2:3:4:5:6:7:8:9'")
    # zonewatch waits a moment before it actually updates the file
    machine.wait_until_succeeds("grep ' 2 ; serial' '/var/lib/bind/zones/example.org.zone'", timeout=30)
    query("example.org", "A", "2.3.4.5")
    query("example.org", "AAAA", "2:3:4:1::5")
    query("test.example.org", "A", "2.3.4.5")
    query("test.example.org", "AAAA", "2:3:4:1::6")
  '';
}
