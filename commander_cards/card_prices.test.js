// Mock the DOM environment
document.body.innerHTML = `
  <div class="card">
    <div class="card-name">Test Card</div>
    <div class="price-info"></div>
  </div>
`;

// Import the functions we want to test
const { getTimestampColor, formatTimestamp, addTimestampToPriceInfo } = require('./card_prices.js');

// Helper function to convert hex to RGB
function hexToRgb(hex) {
  const result = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
  return result ? `rgb(${parseInt(result[1], 16)}, ${parseInt(result[2], 16)}, ${parseInt(result[3], 16)})` : null;
}

describe('Timestamp Color Functionality', () => {
  let priceInfo;
  
  beforeEach(() => {
    // Reset the DOM before each test
    priceInfo = document.querySelector('.price-info');
    priceInfo.innerHTML = '';
    
    // Mock Date.now() to return a fixed timestamp
    jest.useFakeTimers();
    // Use UTC time to avoid timezone issues
    jest.setSystemTime(new Date('2024-03-15T12:00:00.000Z'));
  });
  
  afterEach(() => {
    jest.useRealTimers();
  });
  
  test('getTimestampColor returns correct colors based on age', () => {
    const now = Date.now();
    const oneMonth = 30 * 24 * 60 * 60 * 1000;
    const threeMonths = 3 * oneMonth;
    
    // Test recent timestamp (less than 1 month)
    const recentTimestamp = now - (15 * 24 * 60 * 60 * 1000); // 15 days ago
    expect(getTimestampColor(recentTimestamp)).toBe('#1a8c1a'); // Dark green
    
    // Test old timestamp (1-3 months)
    const oldTimestamp = now - (45 * 24 * 60 * 60 * 1000); // 45 days ago
    expect(getTimestampColor(oldTimestamp)).toBe('#e67e22'); // Orange
    
    // Test very old timestamp (more than 3 months)
    const veryOldTimestamp = now - (100 * 24 * 60 * 60 * 1000); // 100 days ago
    expect(getTimestampColor(veryOldTimestamp)).toBe('#e74c3c'); // Red
  });
  
  test('addTimestampToPriceInfo applies correct styling', () => {
    const now = Date.now();
    const recentTimestamp = now - (15 * 24 * 60 * 60 * 1000); // 15 days ago
    
    addTimestampToPriceInfo(priceInfo, recentTimestamp);
    
    const timestampDiv = priceInfo.querySelector('div');
    expect(timestampDiv).not.toBeNull();
    expect(timestampDiv.style.fontSize).toBe('0.7em');
    expect(timestampDiv.style.color).toBe(hexToRgb('#1a8c1a')); // Convert hex to RGB
    expect(timestampDiv.style.textAlign).toBe('center');
    expect(timestampDiv.style.display).toBe('block');
    expect(timestampDiv.style.lineHeight).toBe('1.2');
    expect(timestampDiv.style.marginTop).toBe('4px');
  });
  
  test('formatTimestamp formats date correctly', () => {
    const timestamp = new Date('2024-03-15T12:00:00.000Z').getTime();
    const formatted = formatTimestamp(timestamp);
    
    // The exact format will depend on the user's locale, so we'll check for key components
    expect(formatted).toContain('3/15/2024'); // Date
    expect(formatted).toMatch(/\d{2}:\d{2}/); // Any time in HH:MM format
    expect(formatted).toMatch(/at/); // Separator
  });
  
  test('timestamp updates correctly when prices are refreshed', () => {
    // First add a timestamp
    const initialTimestamp = Date.now() - (15 * 24 * 60 * 60 * 1000);
    addTimestampToPriceInfo(priceInfo, initialTimestamp);
    
    // Simulate price refresh after 2 months
    jest.advanceTimersByTime(60 * 24 * 60 * 60 * 1000); // Advance 60 days
    const newTimestamp = Date.now();
    
    // Clear and add new timestamp
    priceInfo.innerHTML = '';
    addTimestampToPriceInfo(priceInfo, newTimestamp);
    
    const timestampDiv = priceInfo.querySelector('div');
    expect(timestampDiv.style.color).toBe(hexToRgb('#1a8c1a')); // Convert hex to RGB
  });
}); 