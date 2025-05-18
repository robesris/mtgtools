// TCGPlayer API configuration
const TCG_API_KEY = 'YOUR_API_KEY_HERE'; // You'll need to replace this with your actual API key
const TCG_API_URL = 'https://api.tcgplayer.com/v1.39.0';

async function updatePrices(cardName, cardElement) {
  const priceInfo = cardElement.querySelector('.price-info');
  priceInfo.innerHTML = '<span class="loading">Loading prices</span>';
  
  // Start the loading animation
  let dots = 0;
  const loadingSpan = priceInfo.querySelector('.loading');
  const loadingInterval = setInterval(() => {
    dots = (dots + 1) % 4;
    loadingSpan.textContent = 'Loading prices' + '.'.repeat(dots);
  }, 500);
  
  try {
    console.log(`Fetching prices for ${cardName}...`);
    const response = await fetch(`http://localhost:4567/prices?card=${encodeURIComponent(cardName)}`);
    const data = await response.json();
    console.log('Received price data:', data);
    
    // Clear the loading animation
    clearInterval(loadingInterval);
    
    if (data.error) {
      console.error('Price data error:', data.error);
      throw new Error(data.error);
    }
    
    if (data.prices) {
      console.log('Processing prices:', data.prices);
      let html = '';
      
      // Helper function to add price to HTML
      const addPrice = (condition, price) => {
        console.log(`Adding price for ${condition}:`, price);
        if (html) html += ' | ';
        // Format the condition for display
        const displayCondition = condition
          .replace('near mint', 'NM')
          .replace('lightly played', 'LP')
          .replace(' foil', ' Foil');
        html += `${displayCondition}: <a href="${price.url}" target="_blank" class="price-link">${price.total}</a>`;
      };
      
      // Process all prices in order: NM, LP, NM Foil, LP Foil
      const conditionOrder = [
        'near mint',
        'lightly played',
        'near mint foil',
        'lightly played foil'
      ];
      
      // First add prices in our preferred order
      conditionOrder.forEach(condition => {
        if (data.prices[condition]) {
          addPrice(condition, data.prices[condition]);
        }
      });
      
      // Then add any other conditions we didn't expect
      Object.entries(data.prices).forEach(([condition, price]) => {
        if (!conditionOrder.includes(condition)) {
          addPrice(condition, price);
        }
      });
      
      console.log('Final HTML:', html);
      priceInfo.innerHTML = html || 'No prices found';
      
      // Store in localStorage for caching
      const cacheData = {
        timestamp: Date.now(),
        prices: data.prices
      };
      localStorage.setItem(`price_${cardName}`, JSON.stringify(cacheData));
      console.log('Cached price data:', cacheData);
    } else {
      console.log('No prices found in data');
      priceInfo.innerHTML = 'No prices found';
    }
  } catch (error) {
    // Clear the loading animation on error too
    clearInterval(loadingInterval);
    console.error('Error fetching prices:', error);
    priceInfo.innerHTML = 'Error loading prices. Please make sure the price proxy server is running.';
  }
}

function loadCachedPrices() {
  console.log("Loading cached prices...");
  const cards = document.querySelectorAll('.card');
  console.log(`Found ${cards.length} cards in the document`);
  
  cards.forEach((card, index) => {
    console.log(`Processing card ${index + 1} of ${cards.length}`);
    const cardName = card.querySelector('.card-name')?.textContent;
    console.log(`Card name: ${cardName}`);
    
    if (!cardName) {
      console.log('No card name found for this element');
      return;
    }
    
    const cacheKey = `price_${cardName}`;
    console.log(`Looking up cache key: ${cacheKey}`);
    const cachedData = localStorage.getItem(cacheKey);
    
    if (cachedData) {
      console.log(`Found cached data for ${cardName}:`, cachedData);
      try {
        const data = JSON.parse(cachedData);
        console.log(`Parsed cache data for ${cardName}:`, data);
        
        if (Date.now() - data.timestamp < 86400000) {
          console.log(`Using cached data for ${cardName}`);
          const prices = data.prices;
          let html = '';
          
          const addPrice = (condition, price) => {
            console.log(`Adding cached price for ${condition}:`, price);
            if (html) { html += ' | '; }
            const displayCondition = condition
              .replace('near mint', 'NM')
              .replace('lightly played', 'LP')
              .replace(' foil', ' Foil');
            html += `${displayCondition}: <a href="${price.url}" target="_blank" class="price-link">${price.total}</a>`;
          };
          
          const conditionOrder = ['near mint', 'lightly played', 'near mint foil', 'lightly played foil'];
          conditionOrder.forEach(condition => {
            if (prices[condition]) {
              addPrice(condition, prices[condition]);
            }
          });
          
          Object.entries(prices).forEach(([condition, price]) => {
            if (!conditionOrder.includes(condition)) {
              addPrice(condition, price);
            }
          });
          
          console.log(`Final cached HTML for ${cardName}:`, html);
          const priceInfo = card.querySelector('.price-info');
          if (priceInfo) {
            priceInfo.innerHTML = html || 'No prices found';
          } else {
            console.log('No .price-info element found for this card');
          }
        } else {
          console.log(`Cache expired for ${cardName}`);
          const priceInfo = card.querySelector('.price-info');
          if (priceInfo) {
            priceInfo.innerHTML = '';
          }
        }
      } catch (e) {
        console.error(`Error parsing cache data for ${cardName}:`, e);
      }
    } else {
      console.log(`No cache found for ${cardName}`);
      const priceInfo = card.querySelector('.price-info');
      if (priceInfo) {
        priceInfo.innerHTML = 'Click to load prices';
      }
    }
  });
  
  console.log('Finished loading cached prices');
}

/* Attach click handlers to cards (and re–attach if DOM is updated) */
function attachClickHandlers() {
  console.log('Attaching click handlers...');
  const cards = document.querySelectorAll('.card');
  console.log(`Found ${cards.length} cards to attach handlers to`);
  
  cards.forEach((card, index) => {
    console.log(`Attaching click handler to card ${index + 1}`);
    card.removeEventListener('click', cardClickHandler);
    card.addEventListener('click', cardClickHandler);
    
    // Add click handlers to price links to stop event propagation
    const priceLinks = card.querySelectorAll('.price-link');
    priceLinks.forEach(link => {
      link.addEventListener('click', (e) => {
        e.stopPropagation();  // Prevent the click from bubbling up to the card
      });
    });
  });
  
  console.log('Finished attaching click handlers');
}

function cardClickHandler() {
  console.log('Card clicked');
  const cardName = this.querySelector('.card-name')?.textContent;
  console.log(`Clicked card name: ${cardName}`);
  if (cardName) {
    updatePrices(cardName, this);
  } else {
    console.log('No card name found for clicked element');
  }
}

// Wait for DOM to be fully loaded before initializing everything
document.addEventListener('DOMContentLoaded', () => {
  console.log('DOM fully loaded, initializing...');
  
  // Load cached prices
  loadCachedPrices();
  
  // Attach click handlers
  attachClickHandlers();
  
  // Set up observer for DOM changes
  const observer = new MutationObserver((mutations) => {
    mutations.forEach((mutation) => {
      if (mutation.type === 'childList' && (mutation.target.classList.contains('card-grid') || mutation.target.closest('.card-grid'))) {
         attachClickHandlers();
      }
    });
  });

  // Only observe if body exists
  if (document.body) {
    observer.observe(document.body, { subtree: true, childList: true });
  } else {
    console.error('Document body not found when setting up observer');
  }
}); 