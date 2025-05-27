// IMPORTANT: Do NOT change any user-facing text (e.g., 'Click to load prices', 'Near Mint', 'Lightly Played', 'Loading prices', etc).
// All such strings must remain EXACTLY as they are, including capitalization and punctuation, regardless of any code changes.

// TCGPlayer API configuration
const TCG_API_KEY = 'YOUR_API_KEY_HERE'; // You'll need to replace this with your actual API key
const TCG_API_URL = 'https://api.tcgplayer.com/v1.39.0';

function getTimestampColor(timestamp) {
  const now = Date.now();
  const oneMonth = 30 * 24 * 60 * 60 * 1000;  // 30 days in milliseconds
  const threeMonths = 3 * oneMonth;
  
  const age = now - timestamp;
  if (age < oneMonth) {
    return '#1a8c1a';  // Darker green for < 1 month
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
    fontSize: '0.7em',  // Slightly larger font
    marginTop: '4px',
    lineHeight: '1.2',
    color: getTimestampColor(timestamp),
    display: 'block',
    textAlign: 'center'  // Center the text horizontally
  });
  timestampDiv.textContent = `Prices retrieved on ${formatTimestamp(timestamp)}`;
  priceInfo.appendChild(timestampDiv);
}

// Function to animate ellipsis
function animateEllipsis(element, text) {
  if (!element) return null;
  let counter = 0;
  const interval = setInterval(() => {
    counter = (counter + 1) % 4;
    element.textContent = text + '.'.repeat(counter);
  }, 500);
  return interval;
}

// Function to create a spinner element
function createSpinner() {
  const spinner = document.createElement('span');
  spinner.className = 'spinner';
  spinner.innerHTML = '⌛';  // Hourglass emoji
  return spinner;
}

// Function to get color for card name
function getCardNameColors(cardElement) {
  const colors = cardElement.getAttribute('data-colors')?.split(',').map(c => c.trim().toLowerCase()) || [];
  if (colors.length === 0) return ['#666666']; // Dark gray for colorless
  if (colors.length === 1) return [getColorCode(colors[0])];
  return colors.map(getColorCode);
}

// Function to get color code for a color
function getColorCode(color) {
  const colorMap = {
    'white': '#F8F8F8',  // White
    'blue': '#0070BA',   // Blue
    'black': '#150B00',  // Black
    'red': '#D3202A',    // Red
    'green': '#00733E',  // Green
    'multicolor': '#A020F0'  // Purple for multicolor
  };
  return colorMap[color.toLowerCase()] || '#666666';
}

// Function to create colored card name span
function createColoredCardName(cardElement) {
  const cardName = cardElement.querySelector('.card-name')?.textContent || '';
  const colors = getCardNameColors(cardElement);
  const span = document.createElement('span');
  
  if (colors.length === 1) {
    span.style.color = colors[0];
    span.textContent = cardName;
  } else if (colors.length > 1) {
    const midPoint = Math.ceil(cardName.length / 2);
    const firstHalf = cardName.substring(0, midPoint);
    const secondHalf = cardName.substring(midPoint);
    
    const firstSpan = document.createElement('span');
    firstSpan.style.color = colors[0];
    firstSpan.textContent = firstHalf;
    
    const secondSpan = document.createElement('span');
    secondSpan.style.color = colors[1];
    secondSpan.textContent = secondHalf;
    
    span.appendChild(firstSpan);
    span.appendChild(secondSpan);
  }
  
  return span;
}

// Update the updateCardPrices function to use ellipsis animation
async function updateCardPrices(cardElement) {
  const cardName = cardElement.querySelector('.card-name').textContent;
  const priceInfo = cardElement.querySelector('.price-info');
  
  priceInfo.innerHTML = '<span class="loading">Loading prices</span>';
  const loadingElement = priceInfo.querySelector('.loading');
  const ellipsisInterval = animateEllipsis(loadingElement, 'Loading prices');

  try {
    const response = await fetch('http://localhost:4567/card_info', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ card: cardName })
    });
    clearInterval(ellipsisInterval);
    
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
    clearInterval(ellipsisInterval);
    console.error('Error updating prices:', error);
    // Show the error message for 5 seconds, then revert to "Click to load prices"
    priceInfo.innerHTML = `<span class="error-message">${error.message || 'Error loading prices'}</span>`;
    setTimeout(() => {
      priceInfo.textContent = 'Click to load prices';
    }, 5000);
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

// Update the fetchAllPrices function to use spinner and colored card names
async function fetchAllPrices() {
  const fetchAllButton = document.getElementById('fetch-all-prices');
  const fetchStatus = document.getElementById('fetch-status');
  const cards = document.querySelectorAll('.card');
  
  if (!fetchAllButton || !fetchStatus) {
    console.error('Required elements not found:', { 
      hasButton: !!fetchAllButton, 
      hasStatus: !!fetchStatus 
    });
    return;
  }
  
  if (fetchAllButton.disabled) return;
  
  fetchAllButton.disabled = true;
  fetchAllButton.style.backgroundColor = '#999';
  
  // Get only cards that are currently visible (not hidden by any filter)
  const visibleCards = Array.from(cards).filter(card => {
    // Check if the card is hidden by any filter
    const isHiddenByColor = card.classList.contains('hidden-by-color');
    const isHiddenByAll = card.classList.contains('hidden-by-all');
    const isHiddenByDisplay = card.style.display === 'none';
    const isHiddenByVisibility = card.style.visibility === 'hidden';
    const isHiddenByOpacity = card.style.opacity === '0';
    
    // Card is visible if it's not hidden by any filter
    return !(isHiddenByColor || isHiddenByAll || isHiddenByDisplay || isHiddenByVisibility || isHiddenByOpacity);
  });
  
  console.log(`Found ${visibleCards.length} visible cards out of ${cards.length} total cards`);
  
  let completed = 0;
  let failed = 0;
  
  // Process each visible card with a delay between requests
  for (const card of visibleCards) {
    try {
      // Clear previous status
      fetchStatus.innerHTML = '';
      
      // Create status container
      const statusContainer = document.createElement('div');
      statusContainer.className = 'fetch-status-container';
      
      // Add colored card name
      const cardNameSpan = createColoredCardName(card);
      statusContainer.appendChild(cardNameSpan);
      
      // Add progress text
      const progressText = document.createElement('span');
      progressText.textContent = ` (${completed + 1}/${visibleCards.length})`;
      statusContainer.appendChild(progressText);
      
      // Add spinner after the text
      const spinner = createSpinner();
      statusContainer.appendChild(spinner);
      
      // Update status
      fetchStatus.appendChild(statusContainer);
      
      // Fetch prices
      await updateCardPrices(card);
      completed++;
      
      // Add a delay between cards to avoid rate limiting
      await new Promise(resolve => setTimeout(resolve, 2000));
    } catch (error) {
      console.error('Error fetching prices for card:', error);
      failed++;
    }
  }
  
  // Clear status and show completion message
  fetchStatus.innerHTML = '';
  const completionMessage = document.createElement('div');
  completionMessage.textContent = `Completed: ${completed} cards fetched${failed > 0 ? `, ${failed} failed` : ''}`;
  fetchStatus.appendChild(completionMessage);
  
  fetchAllButton.disabled = false;
  fetchAllButton.style.backgroundColor = '#4CAF50';
  
  // Clear status message after 5 seconds
  setTimeout(() => {
    fetchStatus.innerHTML = '';
  }, 5000);
}

// Wait for DOM to be fully loaded before initializing everything
document.addEventListener('DOMContentLoaded', () => {
  console.log('DOM fully loaded, initializing...');
  
  // Load cached prices
  loadCachedPrices();
  
  // Attach click handlers
  attachClickHandlers();
  
  // Initialize color filter "only" functionality
  initColorFilterOnly();
  
  // Add refresh button handler
  const fetchAllButton = document.getElementById('fetch-all-prices');
  if (fetchAllButton) {
    console.log('Found fetch all prices button, attaching click handler');
    fetchAllButton.addEventListener('click', fetchAllPrices);
  } else {
    console.error('Fetch all prices button not found');
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

function filterCardsByColor() {
  console.log('Filtering cards by color...');
  const tray = document.querySelector('.color-filter-tray');
  if (!tray) {
    console.error('Color filter tray not found');
    return;
  }

  // Get all checked colors
  const checkedColors = Array.from(tray.querySelectorAll('input[type="checkbox"]:checked'))
    .map(checkbox => checkbox.getAttribute('data-color').toLowerCase());
  
  console.log('Checked colors:', checkedColors);

  // Batch DOM updates to prevent multiple reflows
  requestAnimationFrame(() => {
    // If no colors are checked, show all cards
    if (checkedColors.length === 0) {
      console.log('No colors checked, showing all cards');
      document.querySelectorAll('.card').forEach(card => {
        card.classList.remove('hidden');
      });
      return;
    }

    // Filter cards based on checked colors
    document.querySelectorAll('.card').forEach(card => {
      const cardColors = card.getAttribute('data-colors')?.toLowerCase().split(',') || [];
      console.log('Card colors:', cardColors, 'for card:', card.querySelector('.card-name')?.textContent);
      
      // Show card if it has any of the checked colors
      const shouldShow = cardColors.some(color => checkedColors.includes(color.trim()));
      if (shouldShow) {
        card.classList.remove('hidden');
      } else {
        card.classList.add('hidden');
      }
    });
  });
}

function initColorFilterOnly() {
  console.log('Initializing color filter only functionality...');
  const tray = document.querySelector('.color-filter-tray');
  if (!tray) {
    console.error('Color filter tray not found');
    return;
  }
  console.log('Found color filter tray, attaching click handlers...');
  
  // Batch checkbox changes to prevent multiple reflows
  let isUpdatingCheckboxes = false;
  
  // Attach change handlers to checkboxes
  tray.querySelectorAll('input[type="checkbox"]').forEach(checkbox => {
    checkbox.addEventListener('change', () => {
      if (!isUpdatingCheckboxes) {
        filterCardsByColor();
      }
    });
  });

  // Attach click handlers to only icons
  tray.querySelectorAll('span.only-icon').forEach(icon => {
    console.log('Attaching click handler to icon:', icon.getAttribute('data-color'));
    icon.addEventListener('click', (e) => {
      e.preventDefault(); // Prevent any default behavior
      e.stopPropagation(); // Stop event from bubbling up
      console.log('Only icon clicked:', icon.getAttribute('data-color'));
      
      // Set flag to prevent individual checkbox change handlers from firing
      isUpdatingCheckboxes = true;
      
      const color = icon.getAttribute('data-color');
      tray.querySelectorAll('input[type="checkbox"]').forEach(checkbox => {
        const checkboxColor = checkbox.getAttribute('data-color');
        console.log(`Setting ${checkboxColor} checkbox to ${checkboxColor === color}`);
        checkbox.checked = (checkboxColor === color);
      });
      
      // Trigger filtering once after all checkboxes are updated
      filterCardsByColor();
      
      // Reset flag after a short delay to ensure all updates are complete
      setTimeout(() => {
        isUpdatingCheckboxes = false;
      }, 0);
    });
  });
  console.log('Finished attaching color filter click handlers');
}

// Update CSS styles for the spinner and status container
const style = document.createElement('style');
style.textContent = `
  .spinner {
    display: inline-block;
    animation: spin 1s linear infinite;
    margin-left: 8px;
    font-size: 1.2em;
    font-style: normal;
  }
  
  @keyframes spin {
    0% { transform: rotate(0deg); }
    100% { transform: rotate(360deg); }
  }
  
  .fetch-status-container {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 4px;
    background-color: #333333;
    padding: 8px 16px;
    border-radius: 4px;
    color: #ffffff;
  }
  
  .fetch-status-container span {
    color: inherit;
  }
  
  .loading {
    display: inline-block;
  }
  
  .error-message {
    color: #e74c3c;
    font-style: italic;
  }
`;
document.head.appendChild(style);

// Export functions for testing
if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    getTimestampColor,
    formatTimestamp,
    addTimestampToPriceInfo,
    initColorFilterOnly
  };
} 