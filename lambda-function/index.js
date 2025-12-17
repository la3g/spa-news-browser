// Lambda function to proxy both Gemini API and Supabase queries
const { GoogleGenerativeAI } = require('@google/generative-ai');
const { createClient } = require('@supabase/supabase-js');

exports.handler = async (event) => {
    const headers = {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Content-Type': 'application/json'
    };
    
    if (event.requestContext?.http?.method === 'OPTIONS' || event.requestMethod === 'OPTIONS') {
        return { statusCode: 200, headers, body: '' };
    }
    
    try {
        const { action, ...params } = JSON.parse(event.body);
        
        let result;
        
        switch(action) {
            case 'gemini-group-events':
                result = await handleGeminiGroupEvents(params);
                break;
            case 'supabase-fetch-words':
                result = await handleSupabaseFetchWords(params);
                break;
            case 'supabase-fetch-titles':
                result = await handleSupabaseFetchTitles(params);
                break;
            case 'supabase-fetch-categories':
                result = await handleSupabaseFetchCategories();
                break;
            default:
                throw new Error(`Unknown action: ${action}`);
        }
        
        return {
            statusCode: 200,
            headers,
            body: JSON.stringify(result)
        };
        
    } catch (error) {
        console.error('Error:', error);
        return {
            statusCode: 500,
            headers,
            body: JSON.stringify({ 
                error: error.message || 'Internal server error' 
            })
        };
    }
};

async function handleGeminiGroupEvents({ articles, modelName }) {
    const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
    if (!GEMINI_API_KEY) throw new Error('GEMINI_API_KEY not configured');
    
    const genAI = new GoogleGenerativeAI(GEMINI_API_KEY);
    const model = genAI.getGenerativeModel({ 
        model: modelName || 'gemini-2.0-flash-exp' 
    });
    
    const articlesForApi = articles.map(article => ({
        id: article.id,
        title: article.title
    }));
    
    const prompt = `You are an expert event analysis AI. Your task is to organize the following list of news articles into distinct real-world events in Spanish.

Rules:
1.  Analyze the provided articles, which have an "id" and a "title".
2.  Group articles that refer to the same underlying event.
3.  Return your response as a valid JSON array of objects.
4.  Each object must have two keys: "eventName" (a concise string) and "article_ids" (an array of the original article 'id' strings that belong to that event).
5.  Do not include any text, markdown, or explanations outside of the final JSON array.

Here is the list of articles:
${JSON.stringify(articlesForApi, null, 2)}`;
    
    const result = await model.generateContent(prompt);
    const responseText = result.response.text();
    
    const jsonStart = responseText.indexOf('[');
    const jsonEnd = responseText.lastIndexOf(']') + 1;
    if (jsonStart === -1 || jsonEnd === 0) {
        throw new Error("No valid JSON array found in the response.");
    }
    const jsonString = responseText.substring(jsonStart, jsonEnd);
    return JSON.parse(jsonString);
}

function getSupabaseClient() {
    const SUPABASE_URL = process.env.SUPABASE_URL;
    const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
        throw new Error('Supabase credentials not configured');
    }
    return createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
}

async function handleSupabaseFetchWords({ category }) {
    const supabase = getSupabaseClient();
    let query = supabase
        .from('entities')
        .select('entity, category, frequency')
        .order('frequency', { ascending: false });
    
    if (category) {
        query = query.like('category', `${category}%`);
    }
    
    const { data, error } = await query;
    if (error) throw error;
    
    return data.map(item => ({
        text: item.entity,
        category: item.category,
        frequency: item.frequency
    }));
}

async function handleSupabaseFetchTitles({ word }) {
    const supabase = getSupabaseClient();
    const { data, error } = await supabase
        .from('articles')
        .select('title, domain, published_date')
        .ilike('title', `%${word || ''}%`)
        .order('published_date', { ascending: false });
    
    if (error) throw error;
    
    return data.map((item, index) => ({
        id: `article_${item.title.substring(0,10)}_${index}`,
        title: item.title,
        domain: item.domain,
        publishDate: item.published_date || new Date().toISOString(),
        relevanceScore: 0,
        mentions: 0,
        url: `http://${item.domain}`,
        excerpt: ''
    }));
}

async function handleSupabaseFetchCategories() {
    return [
        'Evento', 'Equipo', 'Lugar', 'Organización', 
        'Persona', 'Medio', 'Marca', 'Grupo', 
        'Fenómeno', 'Concepto', 'Ciudad'
    ];
}

