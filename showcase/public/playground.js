document.addEventListener("DOMContentLoaded", () => {
    const runBtn = document.getElementById("run-btn");
    const logs = document.getElementById("logs");
    const editor = document.getElementById("code-editor");
    
    if(!runBtn || !logs || !editor) return;

    const appendLog = (text, className = "text-slate-300", delay = 0) => {
        return new Promise(resolve => {
            setTimeout(() => {
                const div = document.createElement("div");
                div.className = className;
                div.innerHTML = text; // Safe for demo
                logs.appendChild(div);
                logs.parentElement.scrollTop = logs.parentElement.scrollHeight;
                resolve();
            }, delay);
        });
    };

    runBtn.addEventListener("click", async () => {
        runBtn.disabled = true;
        runBtn.classList.add("opacity-50", "cursor-not-allowed");
        
        logs.innerHTML = "";
        await appendLog("> Uploading AST to memory mapped VM...", "text-indigo-400", 100);
        
        const code = editor.value;
        const structMatch = code.match(/pub const ([a-zA-Z0-9_]+)\s*=\s*struct/);
        const structName = structMatch ? structMatch[1] : "Unknown";
        
        await appendLog(`> Typechecking AST: Found struct '<span class="text-pink-400 font-bold">${structName}</span>'`, "text-slate-300", 400);
        await appendLog("> Generating SQLite Introspection mapping...", "text-emerald-400", 600);
        await appendLog(`> <span class="text-orange-400">PRAGMA table_info("${structName}");</span>`, "text-slate-400 pl-4", 300);
        
        await appendLog("> Computing differential migrations...", "text-slate-300", 500);
        await appendLog(`> ✓ Executing zero-downtime memory sync`, "text-emerald-400 font-bold", 800);
        
        await appendLog("> Simulating API Request Cycle:", "text-indigo-400 mt-4", 400);
        await appendLog(`GET /api/${structName.toLowerCase()}`, "text-slate-300 pl-4", 200);
        await appendLog(`200 OK - Query mapped from Struct memory layout`, "text-emerald-400 pl-8", 500);
        
        await appendLog("<br>// Agentic payload execution completed successfully.", "text-slate-500", 200);
        
        runBtn.disabled = false;
        runBtn.classList.remove("opacity-50", "cursor-not-allowed");
    });
});
