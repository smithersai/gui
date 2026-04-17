import Foundation

enum SmithersHomepageWeb {
    static let html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Smithers | Orchestrator</title>
        <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;600;800&display=swap" rel="stylesheet">
        <style>
            :root {
                --bg-primary: #0a0a0c;
                --bg-secondary: #131316;
                --accent: #5e6ad2;
                --accent-hover: #7b85e0;
                --text-primary: #ffffff;
                --text-secondary: #9ba1a6;
                --border-color: rgba(255, 255, 255, 0.1);
            }
            
            * {
                box-sizing: border-box;
                margin: 0;
                padding: 0;
            }
            
            body {
                font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
                background-color: var(--bg-primary);
                color: var(--text-primary);
                min-height: 100vh;
                display: flex;
                flex-direction: column;
                background-image: 
                    radial-gradient(circle at 15% 50%, rgba(94, 106, 210, 0.15), transparent 25%),
                    radial-gradient(circle at 85% 30%, rgba(139, 92, 246, 0.15), transparent 25%);
                overflow-x: hidden;
            }
            
            nav {
                display: flex;
                justify-content: space-between;
                align-items: center;
                padding: 1.5rem 3rem;
                background: rgba(10, 10, 12, 0.7);
                backdrop-filter: blur(12px);
                border-bottom: 1px solid var(--border-color);
                position: sticky;
                top: 0;
                z-index: 100;
            }
            
            .logo {
                font-size: 1.5rem;
                font-weight: 800;
                letter-spacing: -0.05em;
                background: linear-gradient(135deg, #fff 0%, #a5a5a5 100%);
                -webkit-background-clip: text;
                -webkit-text-fill-color: transparent;
                display: flex;
                align-items: center;
                gap: 0.5rem;
            }
            
            .nav-links {
                display: flex;
                gap: 2rem;
            }
            
            .nav-links a {
                color: var(--text-secondary);
                text-decoration: none;
                font-weight: 400;
                font-size: 0.95rem;
                transition: color 0.2s ease;
            }
            
            .nav-links a:hover {
                color: var(--text-primary);
            }
            
            main {
                flex: 1;
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                padding: 4rem 2rem;
                text-align: center;
                max-width: 1200px;
                margin: 0 auto;
                width: 100%;
            }
            
            h1 {
                font-size: clamp(3rem, 5vw, 5rem);
                font-weight: 800;
                line-height: 1.1;
                letter-spacing: -0.04em;
                margin-bottom: 1.5rem;
                animation: slideUp 0.8s cubic-bezier(0.16, 1, 0.3, 1);
            }
            
            .gradient-text {
                background: linear-gradient(135deg, var(--accent) 0%, #d8b4fe 100%);
                -webkit-background-clip: text;
                -webkit-text-fill-color: transparent;
            }
            
            p.subtitle {
                font-size: 1.25rem;
                color: var(--text-secondary);
                max-width: 600px;
                margin: 0 auto 3rem;
                line-height: 1.6;
                animation: slideUp 1s cubic-bezier(0.16, 1, 0.3, 1);
            }
            
            .cta-group {
                display: flex;
                gap: 1rem;
                justify-content: center;
                animation: slideUp 1.2s cubic-bezier(0.16, 1, 0.3, 1);
            }
            
            .btn {
                padding: 0.75rem 1.5rem;
                border-radius: 8px;
                font-weight: 600;
                font-size: 1rem;
                text-decoration: none;
                transition: all 0.2s ease;
                display: inline-flex;
                align-items: center;
                gap: 0.5rem;
            }
            
            .btn-primary {
                background-color: var(--accent);
                color: white;
                box-shadow: 0 4px 14px 0 rgba(94, 106, 210, 0.39);
            }
            
            .btn-primary:hover {
                background-color: var(--accent-hover);
                box-shadow: 0 6px 20px rgba(94, 106, 210, 0.23);
                transform: translateY(-2px);
            }
            
            .btn-secondary {
                background-color: transparent;
                color: var(--text-primary);
                border: 1px solid var(--border-color);
            }
            
            .btn-secondary:hover {
                background-color: rgba(255, 255, 255, 0.05);
                border-color: rgba(255, 255, 255, 0.2);
            }
            
            .features-grid {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
                gap: 2rem;
                width: 100%;
                margin-top: 5rem;
                animation: fadeIn 1.5s ease;
            }
            
            .feature-card {
                background: linear-gradient(180deg, rgba(255,255,255,0.03) 0%, rgba(255,255,255,0.01) 100%);
                border: 1px solid var(--border-color);
                border-radius: 16px;
                padding: 2rem;
                text-align: left;
                transition: transform 0.3s ease, border-color 0.3s ease;
                backdrop-filter: blur(10px);
            }
            
            .feature-card:hover {
                transform: translateY(-4px);
                border-color: rgba(255, 255, 255, 0.2);
                box-shadow: 0 10px 30px rgba(0,0,0,0.2);
            }
            
            .feature-icon {
                font-size: 1.5rem;
                margin-bottom: 1rem;
                color: var(--accent);
                background: rgba(94, 106, 210, 0.1);
                width: 48px;
                height: 48px;
                display: flex;
                align-items: center;
                justify-content: center;
                border-radius: 12px;
            }
            
            .feature-card h3 {
                font-size: 1.25rem;
                margin-bottom: 0.75rem;
                font-weight: 600;
            }
            
            .feature-card p {
                color: var(--text-secondary);
                line-height: 1.5;
                font-size: 0.95rem;
            }

            @keyframes slideUp {
                from { opacity: 0; transform: translateY(20px); }
                to { opacity: 1; transform: translateY(0); }
            }
            
            @keyframes fadeIn {
                from { opacity: 0; }
                to { opacity: 1; }
            }
            
            /* Terminal Window Mock */
            .terminal-window {
                margin-top: 4rem;
                background: #1e1e1e;
                border-radius: 12px;
                border: 1px solid var(--border-color);
                width: 100%;
                max-width: 800px;
                overflow: hidden;
                box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
                animation: slideUp 1.4s cubic-bezier(0.16, 1, 0.3, 1);
                text-align: left;
            }
            
            .terminal-header {
                background: #2d2d2d;
                padding: 0.75rem 1rem;
                display: flex;
                gap: 0.5rem;
                border-bottom: 1px solid rgba(255,255,255,0.05);
            }
            
            .terminal-dot {
                width: 12px;
                height: 12px;
                border-radius: 50%;
            }
            .dot-red { background: #ff5f56; }
            .dot-yellow { background: #ffbd2e; }
            .dot-green { background: #27c93f; }
            
            .terminal-body {
                padding: 1.5rem;
                font-family: 'Menlo', 'Monaco', 'Courier New', monospace;
                font-size: 0.9rem;
                color: #e6e6e6;
                line-height: 1.6;
            }
            
            .cmd-prompt { color: var(--accent); }
            .cmd-comment { color: #6a9955; }
        </style>
    </head>
    <body>
        <nav>
            <div class="logo">
                <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <polygon points="12 2 2 7 12 12 22 7 12 2"></polygon>
                    <polyline points="2 17 12 22 22 17"></polyline>
                    <polyline points="2 12 12 17 22 12"></polyline>
                </svg>
                Smithers
            </div>
            <div class="nav-links">
                <a href="#features">Features</a>
                <a href="#docs">Documentation</a>
                <a href="#github">GitHub</a>
            </div>
        </nav>
        
        <main>
            <h1>Durable AI <span class="gradient-text">Orchestration</span></h1>
            <p class="subtitle">Smithers provides resilient, event-sourced workflow execution for LLM agents. Built for complex cognitive architectures.</p>
            
            <div class="cta-group">
                <a href="#start" class="btn btn-primary">
                    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14M12 5l7 7-7 7"/></svg>
                    Get Started
                </a>
                <a href="#cli" class="btn btn-secondary">View CLI Commands</a>
            </div>
            
            <div class="terminal-window">
                <div class="terminal-header">
                    <div class="terminal-dot dot-red"></div>
                    <div class="terminal-dot dot-yellow"></div>
                    <div class="terminal-dot dot-green"></div>
                </div>
                <div class="terminal-body">
                    <span class="cmd-comment"># Start an AI workflow execution in the background</span><br>
                    <span class="cmd-prompt">$</span> smithers up -d<br><br>
                    <span class="cmd-comment"># Check the active runs</span><br>
                    <span class="cmd-prompt">$</span> smithers ps<br>
                    <span style="color: #4CAF50;">RUN       STATUS    WORKFLOW          AGE</span><br>
                    <span>e7a2cf    running   ticket-kanban     2m</span><br>
                </div>
            </div>
            
            <div class="features-grid" id="features">
                <div class="feature-card">
                    <div class="feature-icon">
                        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
                    </div>
                    <h3>Time Travel</h3>
                    <p>Compare time-travel snapshots of your AI runs. Revert workspace states to previous step checkpoints seamlessly.</p>
                </div>
                <div class="feature-card">
                    <div class="feature-icon">
                        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><polyline points="3.27 6.96 12 12.01 20.73 6.96"/><line x1="12" y1="22.08" x2="12" y2="12"/></svg>
                    </div>
                    <h3>Durable Execution</h3>
                    <p>Event-sourced architecture ensuring no work is ever lost. If a node fails, it restarts right where it left off.</p>
                </div>
                <div class="feature-card">
                    <div class="feature-icon">
                        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/><polyline points="10 9 9 9 8 9"/></svg>
                    </div>
                    <h3>Human-in-the-Loop</h3>
                    <p>Safely halt agents at Approval Gates. Approve, deny, or hijack sessions to help the AI complete complex maneuvers.</p>
                </div>
            </div>
        </main>
        <script>
            // Add subtle mouse move gradient effect
            document.addEventListener('mousemove', (e) => {
                const x = e.clientX / window.innerWidth;
                const y = e.clientY / window.innerHeight;
                document.body.style.backgroundImage = `
                    radial-gradient(circle at ${x * 100}% ${y * 100}%, rgba(94, 106, 210, 0.1), transparent 25%),
                    radial-gradient(circle at ${(1-x) * 100}% ${(1-y) * 100}%, rgba(139, 92, 246, 0.1), transparent 25%)
                `;
            });
        </script>
    </body>
    </html>
    """
}
