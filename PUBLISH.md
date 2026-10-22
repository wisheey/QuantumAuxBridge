# Publish Quantum Aux on GitHub Pages

This package adds only `docs/` to wisheey/QuantumAuxBridge. It does not replace the app source or iOS build workflow. Check whether your repository already has a docs folder before merging; preserve any existing documentation.

1. Extract this ZIP on Windows.
2. In https://github.com/wisheey/QuantumAuxBridge choose Add file → Upload files.
3. Drag the **docs folder** into the upload area so that `docs/index.html` appears at the repository root. Commit to the default branch.
4. Open Settings → Pages. Choose **Deploy from a branch**, select that branch and **/docs**, then Save.
5. Wait for the Pages deployment to succeed. The standard URL is https://wisheey.github.io/QuantumAuxBridge/ unless a custom domain is configured.

GitHub Pages availability for private repositories depends on your GitHub plan. Do not change repository visibility unless you intend to make it public. The published page and included downloads are public. No console configuration, keys, provisioning profiles or personal IP addresses are included.

The `downloads` folder contains the latest retrieved Windows package, unsigned IPA 1.0.3 and iOS source. The IPA retains the earlier native limits; the page explains this. It is not an App Store distribution and must be signed for installation.

The hero is an explicitly labeled interactive UI illustration, not a screenshot from a connected console. Its faders never send network requests. The website does not host the local mixer backend.

Official publishing guide: https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site
