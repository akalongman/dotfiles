---
name: weather-fetcher
description: Use when current weather or temperature data is needed for a city from the Open-Meteo API. Takes the city as an argument; defaults to Tbilisi, Georgia when no city is given.
user-invocable: false
---

# Weather Fetcher Skill

This skill provides instructions for fetching current weather data for any city.

## Task

Fetch the current temperature for the requested city in the requested unit (Celsius or Fahrenheit).

## Input

- **City**: the skill argument (for example `Oslo` or `Oslo, Norway`). When no city is given, use Tbilisi, Georgia.
- **Unit**: Celsius unless the caller asked for Fahrenheit.

## Instructions

1. **Resolve coordinates**:
   - Tbilisi (the default) is preresolved: latitude 41.6938, longitude 44.8015. Skip to step 2.
   - For any other city, use the WebFetch tool on the Open-Meteo geocoding API:

     `https://geocoding-api.open-meteo.com/v1/search?name=<city>&count=1`

   - Pass only the city name in `name` (URL-encoded), without country or region (`Oslo`, not `Oslo, Norway`); extra qualifiers can make the geocoder return no results.
   - Extract `results[0].latitude` and `results[0].longitude`. Check `results[0].name` and `results[0].country` against what the caller asked for; if the caller named a country and it does not match, say so.
   - If `results` is empty or missing, report that the city could not be found and stop. Do not guess coordinates.

2. **Fetch Weather Data**: Use the WebFetch tool with the resolved coordinates:

   `https://api.open-meteo.com/v1/forecast?latitude=<lat>&longitude=<lon>&current=temperature_2m&temperature_unit=<celsius|fahrenheit>`

3. **Extract Temperature**: From the JSON response, extract the current temperature:
   - Field: `current.temperature_2m`
   - Unit label is in: `current_units.temperature_2m`

4. **Return Result**: Return the resolved city name, the temperature value, and the unit clearly.

## Expected Output

After completing this skill's instructions:
```
Current [City] Temperature: [X]°[C/F]
Unit: [Celsius/Fahrenheit]
```

## Notes

- Only fetch the temperature, do not perform any transformations or write any files
- Open-Meteo is free, requires no API key, and uses coordinate-based lookups for reliability
- With no city argument this skill defaults to Tbilisi, latitude 41.6938, longitude 44.8015
- Return the numeric temperature value and unit clearly
- Support both Celsius and Fahrenheit based on the caller's request
