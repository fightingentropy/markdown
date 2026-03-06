enum PreviewStylesheet {

    static func page(body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>\(css)</style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    static let css = """
    * { margin: 0; padding: 0; box-sizing: border-box; }

    :root { color-scheme: light dark; }

    body {
        font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif;
        font-size: 15px;
        line-height: 1.75;
        color: #1d1d1f;
        background: #ffffff;
        padding: 32px 40px;
        -webkit-font-smoothing: antialiased;
    }

    @media (prefers-color-scheme: dark) {
        body { color: #f5f5f7; background: #1e1e1e; }
    }

    h1, h2, h3, h4, h5, h6 {
        font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', sans-serif;
        font-weight: 700;
        line-height: 1.3;
        margin-top: 1.6em;
        margin-bottom: 0.6em;
        letter-spacing: -0.01em;
    }

    h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }

    h1 {
        font-size: 2.2em;
        font-weight: 800;
        letter-spacing: -0.025em;
        border-bottom: 1px solid #d2d2d7;
        padding-bottom: 0.35em;
    }

    h2 {
        font-size: 1.6em;
        border-bottom: 1px solid rgba(210,210,215,0.4);
        padding-bottom: 0.25em;
    }

    h3 { font-size: 1.3em; }
    h4 { font-size: 1.1em; }
    h5, h6 { font-size: 1em; color: #86868b; }

    @media (prefers-color-scheme: dark) {
        h1 { border-bottom-color: #424245; }
        h2 { border-bottom-color: rgba(66,66,69,0.5); }
        h5, h6 { color: #a1a1a6; }
    }

    p { margin: 0.85em 0; }

    a {
        color: #0071e3;
        text-decoration: none;
        border-bottom: 1px solid rgba(0,113,227,0.3);
        transition: border-color 0.15s;
    }

    a:hover { border-bottom-color: #0071e3; }

    @media (prefers-color-scheme: dark) {
        a { color: #2997ff; border-bottom-color: rgba(41,151,255,0.3); }
        a:hover { border-bottom-color: #2997ff; }
    }

    strong { font-weight: 600; }
    em { font-style: italic; }
    del { text-decoration: line-through; opacity: 0.6; }

    code {
        font-family: 'SF Mono', SFMono-Regular, Menlo, monospace;
        font-size: 0.88em;
        background: rgba(0,0,0,0.05);
        padding: 0.15em 0.45em;
        border-radius: 5px;
    }

    @media (prefers-color-scheme: dark) {
        code { background: rgba(255,255,255,0.08); }
    }

    pre {
        background: #f5f5f7;
        border-radius: 10px;
        padding: 18px 22px;
        overflow-x: auto;
        margin: 1.2em 0;
        border: 1px solid rgba(0,0,0,0.06);
    }

    pre code {
        background: none;
        padding: 0;
        font-size: 0.85em;
        line-height: 1.6;
        border-radius: 0;
    }

    @media (prefers-color-scheme: dark) {
        pre { background: #1c1c1e; border-color: rgba(255,255,255,0.06); }
    }

    blockquote {
        border-left: 3px solid #0071e3;
        margin: 1.2em 0;
        padding: 0.6em 1.2em;
        color: #6e6e73;
        background: rgba(0,113,227,0.04);
        border-radius: 0 8px 8px 0;
    }

    @media (prefers-color-scheme: dark) {
        blockquote {
            color: #a1a1a6;
            border-left-color: #2997ff;
            background: rgba(41,151,255,0.06);
        }
    }

    ul, ol { padding-left: 1.6em; margin: 0.85em 0; }
    li { margin: 0.35em 0; }
    li > ul, li > ol { margin: 0.2em 0; }

    li::marker { color: #86868b; }

    @media (prefers-color-scheme: dark) {
        li::marker { color: #636366; }
    }

    hr {
        border: none;
        height: 1px;
        background: linear-gradient(to right, transparent, #d2d2d7, transparent);
        margin: 2.5em 0;
    }

    @media (prefers-color-scheme: dark) {
        hr { background: linear-gradient(to right, transparent, #424245, transparent); }
    }

    table {
        border-collapse: collapse;
        width: 100%;
        margin: 1.2em 0;
        font-size: 0.95em;
    }

    th, td {
        border: 1px solid #d2d2d7;
        padding: 10px 14px;
        text-align: left;
    }

    th {
        background: rgba(0,0,0,0.03);
        font-weight: 600;
        font-size: 0.9em;
        text-transform: uppercase;
        letter-spacing: 0.03em;
    }

    @media (prefers-color-scheme: dark) {
        th, td { border-color: #424245; }
        th { background: rgba(255,255,255,0.04); }
    }

    img {
        max-width: 100%;
        border-radius: 10px;
        margin: 1em 0;
    }

    img.mermaid {
        border-radius: 12px;
        max-width: 100%;
        height: auto;
    }
    """
}
