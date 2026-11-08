browser.runtime.onMessageExternal && browser.runtime.onMessageExternal.addListener((m, s, reply) => { reply({ echo: m }); });
