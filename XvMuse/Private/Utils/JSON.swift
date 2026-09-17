//
//  JSON.swift
//  XvUtils
//
//  Created by Jason Snell on 6/18/20.
//  Copyright © 2020 Jason J. Snell. All rights reserved.
//

import Foundation

//PUBLIC ON PURPOSE, despite the folder name: sibling Xv projects import
//this directly. Narrowing it would break them. See the access-level note
//in XvMuse.swift.
public class JSON {
    
    public class func getJSON(fromStr:String) -> [String:Any]? {
        
        //turn the string into a data object
        let data:Data = Data(fromStr.utf8)
        
        do {
            // make sure this JSON is in the format we expect
            if let json:[String:Any] = try JSONSerialization.jsonObject(with: data, options:[]) as? [String: Any] {
                
                //print success
                return json
            
            }
        } catch let error as NSError {
            print("XvUtils: JSON: Error:", fromStr)
            print("XvUtils: JSON: Error:", (error.localizedDescription))
        }
        return nil
    }

    
}


