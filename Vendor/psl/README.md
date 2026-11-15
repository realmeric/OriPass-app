# Public Suffix List

`public_suffix_list.dat` as publicsuffix.org served it on 2026-10-09, from
https://publicsuffix.org/list/public_suffix_list.dat and nowhere else, as its
own header asks. Its header gives the version, 2026-10-07_07-28-19_UTC, and the
commit, 3929462652695bad04f0a27afb600974014a3c8b. The file is as it came, both
sections, 10,336 rules.

SHA-256 `ba7d836c0ea57a8bcf9f1fcb868066a7554bed029b441ecc6204ad8494a32612`.

It is under the Mozilla Public License 2.0, whose text is in `LICENSE`. The
file is copied into the app's bundle unchanged and read by
`Sources/Front/PublicSuffix.swift`.

To bring it up to date, download the file again over this one and change the
date, the version, the commit, the count and the sum above.
`URIMatchTests.testTheVendoredListIsInTheBundleAndReadsWhole` says whether the
new one still reads, and holds the count.
