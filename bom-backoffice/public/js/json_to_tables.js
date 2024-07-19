// this file is used to convert json data to tables

// Populate the container with the data
// data: the data to be displayed
// maxCols: the maximum number of columns in a table
// entity_unique_id: the unique id of the entity
function populateContainer(data, maxCols, entity_unique_id) {
    let tableContainer = document.querySelector(entity_unique_id)

    tableContainer.innerHTML = "";

    data.forEach(result => {
        let resultBox = createResultBox(result, maxCols);
        tableContainer.appendChild(resultBox);
        //add divider
        let divider = document.createElement("hr");
        //make the divider more visible
        divider.style.border = "2px solid";
        tableContainer.appendChild(divider);
        tableContainer.appendChild(divider);
    });
}

// Create the headers for the table
// obj: the object to create headers for
function createHeaders(obj) {
    return Object.keys(obj);
}

// Create a table row
// obj: the object to create a row for
// headers: the headers of the table
// entity_unique_id: the unique id of the entity
function createTableRow(obj, headers, entity_unique_id) {
    let row = document.createElement("tr");
    headers.forEach(header => {
        let td = document.createElement("td");
        let value = obj[header];
        if (Array.isArray(value)) {
            if (typeof value[0] === 'object') {
                let anchor = document.createElement("a");
                anchor.href = "#" + header + "_" + entity_unique_id;
                anchor.textContent = "[Nested Table]";
                td.appendChild(anchor);
            } else {
                td.textContent = value.join(', ');
            }
        } else if (typeof value === 'object' && value !== null) {
            let anchor = document.createElement("a");
            anchor.href = "#" + header + "_" + entity_unique_id;
            anchor.textContent = "[Nested Table]";
            td.appendChild(anchor);
        } else {
            if (value !== undefined && value !== null) {
                if (typeof value === 'string' && value.startsWith('http')) {
                    let anchor = document.createElement("a");
                    anchor.href = value;
                    anchor.textContent = value;
                    td.appendChild(anchor);
                } else {
                    if (typeof value === 'string' && value.includes('<br>')) {
                        let temp = value.split('<br>');
                        let p = document.createElement('p');
                        temp.forEach((element) => {
                            p.appendChild(document.createTextNode(element));
                            p.appendChild(document.createElement('br'));
                        });
                        td.appendChild(p);
                    } else {
                        td.innerHTML = value;
                    }
                }
            } else {
                td.textContent = '';
            }
        }
        row.appendChild(td);
    });
    return row;
}

// Create a table
// data: the data to be displayed
// headers: the headers of the table
// entity_unique_id: the unique id of the entity
function createTable(data, headers, entity_unique_id) {
    let table = document.createElement("table");
    table.classList.add("jsonTable");

    let tableHead = document.createElement("thead");
    let tableBody = document.createElement("tbody");

    table.appendChild(tableHead);
    table.appendChild(tableBody);

    let headerRow = document.createElement("tr");
    headers.forEach(header => {
        let th = document.createElement("th");
        th.textContent = header;
        headerRow.appendChild(th);
    });
    tableHead.appendChild(headerRow);

    data.forEach(item => {
        let row = createTableRow(item, headers, entity_unique_id);
        tableBody.appendChild(row);
    });

    return table;
}

// Split the table into multiple tables
// data: the data to be displayed
// maxCols: the maximum number of columns in a table
// entity_unique_id: the unique id of the entity
function splitTable(data, maxCols, entity_unique_id) {
    let headers = createHeaders(data[0]);
    let resultTables = [];
    for (let i = 0; i < headers.length; i += maxCols) {
        let chunkHeaders = headers.slice(i, i + maxCols);
        resultTables.push(createTable(data, chunkHeaders, entity_unique_id));
    }
    return resultTables;
}

// Create a result box
// result: the result to be displayed
// maxCols: the maximum number of columns in a table
function createResultBox(result, maxCols) {
    let resultBox = document.createElement("div");
    resultBox.classList.add("resultBox");

    let splitTables = splitTable([result], maxCols, result['entity_unique_id']);
    splitTables.forEach((table, index) => {
        if (index > 0) {
            let tableContainer = document.createElement("div");
            tableContainer.classList.add("splitTableContainer");
            tableContainer.appendChild(table);
            resultBox.appendChild(tableContainer);
        } else {
            resultBox.appendChild(table);
        }
    });

    // Check for nested arrays of objects or nested objects
    Object.keys(result).forEach(key => {
        let value = result[key];
        if (Array.isArray(value) && value.length > 0 && typeof value[0] === 'object') {
            let nestedTable = createNestedTable(value, key, result['entity_unique_id']);
            resultBox.appendChild(nestedTable);
        } else if (typeof value === 'object' && value !== null) {
            let nestedTable;
            if (value['is_comparing'] === 1) {
                nestedTable = createComparingTable(value, key);
            } else {
                nestedTable = createNestedTable([value], key, result['entity_unique_id']);
            }
            resultBox.appendChild(nestedTable);
        }
    });

    return resultBox;
}

// Create a nested table
// data: the data to be displayed
// title: the title of the table
// entity_unique_id: the unique id of the entity
function createNestedTable(data, title, entity_unique_id) {
    let nestedTableContainer = document.createElement("div");

    let nestedTableTitle = document.createElement("h2");
    nestedTableTitle.classList.add("nestedTableTitle");
    nestedTableTitle.id = title + "_" + entity_unique_id;
    nestedTableTitle.textContent = title;
    nestedTableTitle.style.fontSize = "2em"; // Increase font size
    nestedTableContainer.appendChild(nestedTableTitle);

    let nestedTable = createTable(data, createHeaders(data[0]), entity_unique_id);
    nestedTableContainer.appendChild(nestedTable);

    // Check for further nested layers
    data.forEach(item => {
        Object.keys(item).forEach(key => {
            let value = item[key];
            if (Array.isArray(value) && value.length > 0 && typeof value[0] === 'object') {
                let furtherNestedTable = createNestedTable(value, key, entity_unique_id);
                nestedTableContainer.appendChild(furtherNestedTable);
            } else if (typeof value === 'object' && value !== null) {
                let furtherNestedTable = createNestedTable([value], key, entity_unique_id);
                nestedTableContainer.appendChild(furtherNestedTable);
            }
        });
    });

    return nestedTableContainer;
}

// Create a comparing table
// json: the data to be displayed
// title: the title of the table
function createComparingTable(json, title) {

    let comparingTable = document.createElement("table");
    comparingTable.classList.add("jsonTable");

    let tableHead = document.createElement("thead");
    let tableBody = document.createElement("tbody");
    comparingTable.appendChild(tableHead);
    comparingTable.appendChild(tableBody);

    // Create the header row
    let headerRow = document.createElement("tr");
    let th = document.createElement("th");
    th.style.fontWeight = "bold";
    th.style.backgroundColor = "lightgrey";
    th.textContent = "Keys";
    headerRow.appendChild(th);

    let keys = Object.keys(json).filter(key => key !== 'is_comparing');
    keys.forEach(key => {
        let th = document.createElement("th");
        th.textContent = key;
        headerRow.appendChild(th);
    });

    tableHead.appendChild(headerRow);

    // Gather all unique subkeys
    let allSubKeys = new Set();
    keys.forEach(key => {
        Object.keys(json[key]).forEach(subKey => {
            allSubKeys.add(subKey);
        });
    });

    // Create the data rows
    allSubKeys.forEach(subKey => {
        let dataRow = document.createElement("tr");

        let keyCell = document.createElement("td");
        keyCell.style.fontWeight = "bold";
        keyCell.style.backgroundColor = "lightgrey";
        keyCell.textContent = subKey;
        dataRow.appendChild(keyCell);

        keys.forEach(key => {
            let valueCell = document.createElement("td");
            valueCell.innerHTML = json[key][subKey] || "";
            dataRow.appendChild(valueCell);
        });

        tableBody.appendChild(dataRow);
    });

    return comparingTable;
}

// Add smooth scrolling to anchor links
document.addEventListener('DOMContentLoaded', function () {
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function (e) {
            e.preventDefault();

            document.querySelector(this.getAttribute('href')).scrollIntoView({
                behavior: "smooth", block: "center", inline: "nearest"
            });
        });
    });
});
