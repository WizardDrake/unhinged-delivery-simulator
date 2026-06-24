document.addEventListener('DOMContentLoaded', () => {
    // Smooth scrolling for anchor links
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function (e) {
            e.preventDefault();
            const target = document.querySelector(this.getAttribute('href'));
            if (target) {
                target.scrollIntoView({
                    behavior: 'smooth'
                });
            }
        });
    });

    // Custom Cursor Glow effect that follows mouse
    const cursorGlow = document.getElementById('cursor-glow');
    if (cursorGlow) {
        document.addEventListener('mousemove', (e) => {
            cursorGlow.style.left = e.clientX + 'px';
            cursorGlow.style.top = e.clientY + 'px';
        });

        // Interactive states for links and buttons
        const interactables = document.querySelectorAll('a, button');
        interactables.forEach(item => {
            item.addEventListener('mouseenter', () => {
                cursorGlow.style.width = '800px';
                cursorGlow.style.height = '800px';
                cursorGlow.style.background = 'radial-gradient(circle, rgba(0, 240, 255, 0.08) 0%, rgba(0,0,0,0) 60%)';
            });
            item.addEventListener('mouseleave', () => {
                cursorGlow.style.width = '600px';
                cursorGlow.style.height = '600px';
                cursorGlow.style.background = 'radial-gradient(circle, rgba(252, 238, 10, 0.05) 0%, rgba(0,0,0,0) 60%)';
            });
        });
    }

    // Interactive feature cards
    const cards = document.querySelectorAll('.feature-card');
    cards.forEach(card => {
        card.addEventListener('mousemove', (e) => {
            const rect = card.getBoundingClientRect();
            const x = e.clientX - rect.left;
            const y = e.clientY - rect.top;
            
            card.style.setProperty('--mouse-x', `${x}px`);
            card.style.setProperty('--mouse-y', `${y}px`);
        });
    });

    // Add visual "glitch" color swapping when hovering on the main button
    const primaryBtn = document.querySelector('.primary-btn');
    if (primaryBtn) {
        primaryBtn.addEventListener('mouseenter', () => {
            const originalColor = getComputedStyle(document.body).getPropertyValue('--primary');
            document.body.style.setProperty('--primary', '#00f0ff');
            setTimeout(() => {
                document.body.style.setProperty('--primary', originalColor);
            }, 150);
        });
    }
});
