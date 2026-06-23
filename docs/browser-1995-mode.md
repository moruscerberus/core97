# Browser professional mode

This patch changes the Internet Browser from a Google compatibility placeholder into a usable web browser flow.

What works now:
- Address bar browsing for simple HTTP-style pages.
- Search box opens text search results.
- Clickable blue links with Back/Reload/Go.
- professional-friendly web directory pages: Yahoo, AltaVista, CERN, W3C, TEXTFILES, FrogFind, Example, NeverSSL.
- HTTPS URLs no longer stop at a TLS error; they are shown through a simplified text gateway page so the browser stays usable.

Important limitation:
- This is deliberately "Internet like professional": plain text, links, no JavaScript, no CSS layout, no images, no real TLS certificate validation yet.
- Modern Google cannot be rendered as Chrome/Firefox would render it until the OS has a real TLS + HTML/CSS/JS engine.

Good test URLs:
- http://yahoo.com
- http://altavista.digital.com
- http://info.cern.ch
- http://w3.org
- http://textfiles.com
- http://frogfind.com
- http://example.com
- http://neverssl.com
