## Custom Fork v19

- Improve autopif4 to fallback to a random device when no matching Pixel Canary build is found
- Add optional skipping of device matching from Action button if skipmatchdevice file exists
- Fix autopif4 Platform Beta check and commented security_patch on TEESim v4.x/OMK
- Update autopif4/migrate for new enforced prop check on all and RKP keybox requirement for some Pixel Canary prints

### Fork build (Forgejo)

- Fix autopif4 to stop and keep the existing custom.pif.prop when migrate.sh fails to convert the new print
- Fix trailing spaces/tabs of custom.pif.prop values being read as part of the value by the Zygisk module
- Fix a custom.pif.prop holding only comments to unload the Zygisk module like a missing config
- Fix WebUI JSON import writing values the Zygisk module would split into extra entries

## Custom Fork v18

- Support further upstream prop area compacting implementation
- Fix autopif4 to check latest Pixel Beta device list
- Fix autopif4 to timeout downloads in case of hung connections
- Update Action for ReSukiSU support and root shell edge cases
- Improve autopif4 to extend TEESim v3.x advanced security_patch.txt setup support to TS-OSS v3.x
- Improve autopif4 to warn TEESim v4.x and OMK need manual config updates
- Fix <A13 PI, Wallet and RCS failures from new GMS detection of Dobby hook

_[Full changelogs](https://github.com/osm0sis/PlayIntegrityFork/releases)_
