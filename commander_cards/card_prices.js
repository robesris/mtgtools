// TCGPlayer API configuration
const TCG_API_KEY = 'YOUR_API_KEY_HERE'; // You'll need to replace this with your actual API key
const TCG_API_URL = 'https://api.tcgplayer.com/v1.39.0';

async function updatePrices(cardName, cardElement) {
  const priceInfo = cardElement.querySelector('.price-info');
  priceInfo.innerHTML = '<span class="loading">Loading prices...</span>';
  
  try {
    console.log(`Fetching prices for ${cardName}...`);
    const response = await fetch(`http://localhost:4567/prices?card=${encodeURIComponent(cardName)}`);
    const data = await response.json();
    console.log('Received price data:', data);
    
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
        html += `${displayCondition}: <a href="${price.url}" target="_blank">${price.total}</a>`;
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
    console.error('Error fetching prices:', error);
    priceInfo.innerHTML = 'Error loading prices. Please make sure the price proxy server is running.';
  }
}

function loadCachedPrices() {
  console.log('Loading cached prices...');
  document.querySelectorAll('.card').forEach(card => {
    const cardName = card.querySelector('.card-name').textContent;
    const cachedData = localStorage.getItem(`price_${cardName}`);
    
    if (cachedData) {
      console.log(`Found cached data for ${cardName}:`, cachedData);
      const data = JSON.parse(cachedData);
      // Only use cache if it's less than 24 hours old
      if (Date.now() - data.timestamp < 86400000) {
        console.log(`Using cached data for ${cardName}`);
        const prices = data.prices;
        let html = '';
        
        // Helper function to add price to HTML
        const addPrice = (condition, price) => {
          console.log(`Adding cached price for ${condition}:`, price);
          if (html) html += ' | ';
          // Format the condition for display
          const displayCondition = condition
            .replace('near mint', 'NM')
            .replace('lightly played', 'LP')
            .replace(' foil', ' Foil');
          html += `${displayCondition}: <a href="${price.url}" target="_blank">${price.total}</a>`;
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
          if (prices[condition]) {
            addPrice(condition, prices[condition]);
          }
        });
        
        // Then add any other conditions we didn't expect
        Object.entries(prices).forEach(([condition, price]) => {
          if (!conditionOrder.includes(condition)) {
            addPrice(condition, price);
          }
        });
        
        console.log(`Final cached HTML for ${cardName}:`, html);
        card.querySelector('.price-info').innerHTML = html || 'No prices found';
      } else {
        console.log(`Cache expired for ${cardName}`);
      }
    } else {
      console.log(`No cache found for ${cardName}`);
    }
  });
}

// Load cached prices on page load
loadCachedPrices();

// Add click handlers for price updates
document.querySelectorAll('.card-clickable').forEach(card => {
  card.addEventListener('click', function() {
    const cardName = this.querySelector('.card-name').textContent;
    const cardElement = this.closest('.card');  // Get the parent card element
    updatePrices(cardName, cardElement);
  });
}); 