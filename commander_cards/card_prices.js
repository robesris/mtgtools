// TCGPlayer API configuration
const TCG_API_KEY = 'YOUR_API_KEY_HERE'; // You'll need to replace this with your actual API key
const TCG_API_URL = 'https://api.tcgplayer.com/v1.39.0';

function getTimestampColor(timestamp) {
  const now = Date.now();
  const oneMonth = 30 * 24 * 60 * 60 * 1000;  // 30 days in milliseconds
  const threeMonths = 3 * oneMonth;
  
  const age = now - timestamp;
  if (age < oneMonth) {
    return '#2ecc71';  // Green for < 1 month
  } else if (age < threeMonths) {
    return '#e67e22';  // Orange for 1-3 months
  } else {
    return '#e74c3c';  // Red for > 3 months
  }
}

function formatTimestamp(timestamp) {
  const date = new Date(timestamp);
  return date.toLocaleDateString() + ' at ' + date.toLocaleTimeString('en-US', { 
    hour12: false,
    hour: '2-digit',
    minute: '2-digit'
  });
}

function addTimestampToPriceInfo(priceInfo, timestamp) {
  const timestampDiv = document.createElement('div');
  // Set styles directly on the element
  Object.assign(timestampDiv.style, {
    fontSize: '0.65em',
    marginTop: '4px',
    fontStyle: 'italic',
    lineHeight: '1.2',
    color: getTimestampColor(timestamp),
    display: 'block'
  });
  timestampDiv.textContent = `Prices retrieved on ${formatTimestamp(timestamp)}`;
  priceInfo.appendChild(timestampDiv);
}

// Update the updateCardPrices function to use server-provided prices
async function updateCardPrices(cardElement) {
  const cardName = cardElement.querySelector('.card-name').textContent;
  const priceInfo = cardElement.querySelector('.price-info');
  
  priceInfo.innerHTML = '<span class="loading">Loading prices</span>';

  try {
    const response = await fetch(`http://localhost:4567/card_info?card=${encodeURIComponent(cardName)}`);
    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }
    const data = await response.json();

    if (data.error) {
      throw new Error(data.error);
    }

    let priceHtml = '';
    const prices = data.prices;
    const isLegal = data.legality === 'legal';

    if (prices) {
      let priceHtml = '';
      const conditionOrder = ['lightly played', 'near mint'];
      
      // First add prices in our preferred order
      conditionOrder.forEach((condition, index) => {
        if (prices[condition] && prices[condition].price) {
          if (priceHtml) priceHtml += ' | ';
          const displayCondition = condition === 'near mint' ? 'Near Mint' : 'Lightly Played';
          priceHtml += `${displayCondition}: <a href="${prices[condition].url}" target="_blank" class="price-link">${prices[condition].price}</a>`;
        }
      });
      
      // Then add any other conditions that might exist
      Object.entries(prices).forEach(([condition, priceData]) => {
        if (!conditionOrder.includes(condition) && priceData && priceData.price) {
          if (priceHtml) priceHtml += ' | ';
          const displayCondition = condition
            .replace('near mint', 'Near Mint')
            .replace('lightly played', 'Lightly Played')
            .replace(' foil', ' Foil');
          priceHtml += `${displayCondition}: <a href="${priceData.url}" target="_blank" class="price-link">${priceData.price}</a>`;
        }
      });
      
      const now = Date.now();
      // Store the timestamp element if it exists
      const existingTimestamp = priceInfo.querySelector('.price-timestamp');
      // Update the price HTML
      priceInfo.innerHTML = priceHtml;
      // Add the timestamp back if it existed, or create a new one
      if (existingTimestamp) {
        priceInfo.appendChild(existingTimestamp);
      } else {
        addTimestampToPriceInfo(priceInfo, now);
      }
      
      if (!isLegal) {
        priceInfo.classList.add('illegal');
        const illegalNotice = document.createElement('div');
        illegalNotice.className = 'illegal-notice';
        illegalNotice.textContent = `Not legal in Commander (${data.legality})`;
        priceInfo.appendChild(illegalNotice);
      } else {
        priceInfo.classList.remove('illegal');
      }

      // Cache the price data
      const cacheData = {
        prices: prices,
        timestamp: now
      };
      localStorage.setItem(`price_${cardName}`, JSON.stringify(cacheData));
    } else {
      priceInfo.textContent = 'Click to load prices';
    }
  } catch (error) {
    console.error('Error updating prices:', error);
    priceInfo.textContent = 'Click to load prices';
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
              .replace('near mint', 'Near Mint')
              .replace('lightly played', 'Lightly Played')
              .replace(' foil', ' Foil');
            html += `${displayCondition}: <a href="${price.url}" target="_blank" class="price-link">${price.price}</a>`;
          };
          
          const conditionOrder = ['lightly played', 'near mint'];
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
            // Store the timestamp element if it exists
            const existingTimestamp = priceInfo.querySelector('.price-timestamp');
            // Update the price HTML
            priceInfo.innerHTML = html || 'Click to load prices';
            // Add the timestamp back if it existed, or create a new one if we have prices
            if (existingTimestamp) {
              priceInfo.appendChild(existingTimestamp);
            } else if (html) {
              addTimestampToPriceInfo(priceInfo, data.timestamp);
            }
          } else {
            console.log('No .price-info element found for this card');
          }
        } else {
          console.log(`Cache expired for ${cardName}`);
          const priceInfo = card.querySelector('.price-info');
          if (priceInfo) {
            priceInfo.innerHTML = 'Click to load prices';
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
    card.removeEventListener('click', (e) => cardClickHandler.call(card, e));
    card.addEventListener('click', (e) => cardClickHandler.call(card, e));
    
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

function cardClickHandler(e) {
  console.log('Card clicked');
  const cardName = this.querySelector('.card-name')?.textContent;
  console.log(`Clicked card name: ${cardName}`);
  if (cardName) {
    updateCardPrices(this);
  } else {
    console.log('No card name found for clicked element');
  }
}

// Add refresh all prices functionality
async function refreshAllPrices() {
  const button = document.getElementById('refresh-all-prices');
  const cards = document.querySelectorAll('.card');
  
  // Disable the button while refreshing
  button.disabled = true;
  button.textContent = 'Refreshing...';
  
  // Create an array of promises for all price updates
  const updatePromises = Array.from(cards).map(async (card, index) => {
    const cardName = card.querySelector('.card-name')?.textContent;
    if (cardName) {
      console.log(`Starting refresh for card ${index + 1}/${cards.length}: ${cardName}`);
      try {
        await updateCardPrices(card);
        console.log(`Finished refreshing card ${index + 1}/${cards.length}: ${cardName}`);
      } catch (err) {
        console.error(`Error refreshing card ${index + 1}/${cards.length} (${cardName}):`, err);
        // Re-throw so that the outer catch sees it
        throw err;
      }
    } else {
      console.warn(`Card ${index + 1}/${cards.length} has no name, skipping`);
    }
  });
  
  try {
    // Wait for all updates to complete (even if some fail)
    await Promise.allSettled(updatePromises);
    console.log('All price refresh attempts completed');
  } catch (error) {
    console.error('Unexpected error during refresh:', error);
  } finally {
    // Always re-enable the button, even if some updates failed
    console.log('Re-enabling refresh button');
    button.disabled = false;
    button.textContent = 'Refresh All Prices';
  }
}

// Wait for DOM to be fully loaded before initializing everything
document.addEventListener('DOMContentLoaded', () => {
  console.log('DOM fully loaded, initializing...');
  
  // Load cached prices
  loadCachedPrices();
  
  // Attach click handlers
  attachClickHandlers();
  
  // Add refresh button handler
  const refreshButton = document.getElementById('refresh-all-prices');
  if (refreshButton) {
    refreshButton.addEventListener('click', refreshAllPrices);
  }
  
  // Set up observer for DOM changes
  const observer = new MutationObserver((mutations) => {
    mutations.forEach((mutation) => {
      // Only re-attach if the mutation is adding/removing cards (not just updating price text)
      if (mutation.type === 'childList' && 
          (mutation.target.classList.contains('card-grid') || mutation.target.closest('.card-grid')) &&
          // Check if the mutation is actually adding/removing card elements
          Array.from(mutation.addedNodes).some(node => node.classList?.contains('card')) ||
          Array.from(mutation.removedNodes).some(node => node.classList?.contains('card'))) {
        console.log('Card grid structure changed, re-attaching handlers');
        attachClickHandlers();
      }
    });
  });

  // Only observe if body exists
  if (document.body) {
    observer.observe(document.body, { 
      subtree: true, 
      childList: true,
      // Don't observe character data or attributes changes
      characterData: false,
      attributes: false
    });
  } else {
    console.error('Document body not found when setting up observer');
  }
}); 